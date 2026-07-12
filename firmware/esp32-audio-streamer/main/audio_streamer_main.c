// RuView ESP32-S3 audio streamer — INMP441 I2S mic → 16 kHz PCM → UDP to the Pi.
//
// Captures raw audio from the INMP441 and streams little-endian int16 PCM in
// ~20 ms UDP datagrams to the Orange Pi's ruview-audiod (:5006), which runs the
// sound-event inference (YAMNet on the NPU) and fuses it with radar telemetry.
//
// Wiring (INMP441 → ESP32-S3), matching the mic node's proven ESPHome layout:
//   VDD → 3V3     GND → GND     L/R → GND (left channel)
//   SCK → GPIO15 (I2S BCLK)     WS → GPIO16 (I2S WS)     SD → GPIO4 (I2S DIN)
//
// Build: ESP-IDF v5.x.  `idf.py set-target esp32s3 && idf.py build flash monitor`
// Configure Wi-Fi + Pi IP in the #defines below (or via menuconfig Kconfig).

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "driver/i2s_std.h"
#include "lwip/sockets.h"

// ── Configuration ───────────────────────────────────────────────────────────
#define WIFI_SSID     "Firefly"
#define WIFI_PASS     "CHANGE_ME"           // <-- set your Wi-Fi password
#define PI_IP         "192.168.7.205"       // Orange Pi running ruview-audiod
#define PI_UDP_PORT   5006

#define I2S_BCLK      GPIO_NUM_15
#define I2S_WS        GPIO_NUM_16
#define I2S_DIN       GPIO_NUM_4
#define SAMPLE_RATE   16000
#define FRAME_SAMPLES 320                    // 20 ms @ 16 kHz
// INMP441 is 24-bit left-justified in a 32-bit slot. Shift to 16-bit PCM;
// GAIN_SHIFT trades headroom for loudness (14 ≈ +12 dB vs a plain >>16).
#define GAIN_SHIFT    13

static const char *TAG = "audio_streamer";
static EventGroupHandle_t s_wifi_eg;
#define WIFI_CONNECTED_BIT BIT0
static i2s_chan_handle_t s_rx;

// ── Wi-Fi station ───────────────────────────────────────────────────────────
static void wifi_evt(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "Wi-Fi disconnected, retrying");
        esp_wifi_connect();
        xEventGroupClearBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ESP_LOGI(TAG, "Got IP");
        xEventGroupSetBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    }
}

static void wifi_init(void) {
    s_wifi_eg = xEventGroupCreate();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_evt, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_evt, NULL, NULL));
    wifi_config_t wc = { 0 };
    strncpy((char *)wc.sta.ssid, WIFI_SSID, sizeof(wc.sta.ssid) - 1);
    strncpy((char *)wc.sta.password, WIFI_PASS, sizeof(wc.sta.password) - 1);
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));   // no power-save; keep audio smooth
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "Wi-Fi connecting to %s", WIFI_SSID);
    xEventGroupWaitBits(s_wifi_eg, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE, portMAX_DELAY);
}

// ── I2S RX (INMP441, mono left, 32-bit slot) ────────────────────────────────
static void i2s_init(void) {
    i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    ESP_ERROR_CHECK(i2s_new_channel(&cc, NULL, &s_rx));
    i2s_std_config_t std = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = I2S_STD_MSB_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCLK,
            .ws = I2S_WS,
            .dout = I2S_GPIO_UNUSED,
            .din = I2S_DIN,
            .invert_flags = { 0 },
        },
    };
    std.slot_cfg.slot_mask = I2S_STD_SLOT_LEFT;   // INMP441 L/R→GND = left
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(s_rx, &std));
    ESP_ERROR_CHECK(i2s_channel_enable(s_rx));
}

// ── Capture → UDP loop ──────────────────────────────────────────────────────
static void stream_task(void *arg) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(PI_UDP_PORT),
        .sin_addr.s_addr = inet_addr(PI_IP),
    };
    static int32_t raw[FRAME_SAMPLES];
    static int16_t pcm[FRAME_SAMPLES];
    size_t nread;
    ESP_LOGI(TAG, "Streaming PCM16 %d Hz → %s:%d", SAMPLE_RATE, PI_IP, PI_UDP_PORT);
    while (1) {
        if (i2s_channel_read(s_rx, raw, sizeof(raw), &nread, portMAX_DELAY) != ESP_OK) continue;
        int n = nread / sizeof(int32_t);
        for (int i = 0; i < n; i++) {
            int32_t v = raw[i] >> GAIN_SHIFT;
            if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
            pcm[i] = (int16_t)v;
        }
        sendto(sock, pcm, n * sizeof(int16_t), 0, (struct sockaddr *)&dst, sizeof(dst));
    }
}

void app_main(void) {
    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }
    wifi_init();
    i2s_init();
    xTaskCreate(stream_task, "stream", 4096, NULL, 5, NULL);
}
