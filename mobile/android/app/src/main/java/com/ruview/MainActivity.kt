package com.ruview

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.ruview.ui.navigation.RuViewNavigation
import com.ruview.ui.theme.RuViewTheme
import com.ruview.ui.viewmodel.SensingViewModel

class MainActivity : ComponentActivity() {

    private val viewModel: SensingViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RuViewTheme {
                RuViewNavigation(viewModel = viewModel)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Repository manages its own lifecycle as a singleton,
        // but we disconnect here to release the WebSocket when the app is destroyed.
        // On app restart the saved host will be used to reconnect automatically.
        if (isFinishing) {
            viewModel.disconnect()
        }
    }
}
