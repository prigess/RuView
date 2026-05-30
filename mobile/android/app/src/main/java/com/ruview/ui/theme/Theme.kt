package com.ruview.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// RuView brand color palette — deep blue / teal
private val RuViewPrimary = Color(0xFF00B4D8)          // Bright teal
private val RuViewOnPrimary = Color(0xFF002533)
private val RuViewPrimaryContainer = Color(0xFF003B52)
private val RuViewOnPrimaryContainer = Color(0xFF90E8FF)

private val RuViewSecondary = Color(0xFF48CAE4)        // Lighter teal
private val RuViewOnSecondary = Color(0xFF00343F)
private val RuViewSecondaryContainer = Color(0xFF004D5C)
private val RuViewOnSecondaryContainer = Color(0xFFAEEEFF)

private val RuViewTertiary = Color(0xFF0096C7)         // Deeper blue-teal
private val RuViewOnTertiary = Color(0xFF001B26)
private val RuViewTertiaryContainer = Color(0xFF00283A)
private val RuViewOnTertiaryContainer = Color(0xFF7FD5F2)

private val RuViewError = Color(0xFFCF6679)
private val RuViewOnError = Color(0xFF680020)
private val RuViewErrorContainer = Color(0xFF92003A)
private val RuViewOnErrorContainer = Color(0xFFFFD9E2)

private val RuViewBackground = Color(0xFF071318)       // Very dark blue-black
private val RuViewOnBackground = Color(0xFFCCE8F0)

private val RuViewSurface = Color(0xFF0A1E26)          // Dark blue-gray surface
private val RuViewOnSurface = Color(0xFFCCE8F0)
private val RuViewSurfaceVariant = Color(0xFF0E2530)
private val RuViewOnSurfaceVariant = Color(0xFF8BB8C6)

private val RuViewOutline = Color(0xFF396877)

private val RuViewDarkColorScheme = darkColorScheme(
    primary = RuViewPrimary,
    onPrimary = RuViewOnPrimary,
    primaryContainer = RuViewPrimaryContainer,
    onPrimaryContainer = RuViewOnPrimaryContainer,
    secondary = RuViewSecondary,
    onSecondary = RuViewOnSecondary,
    secondaryContainer = RuViewSecondaryContainer,
    onSecondaryContainer = RuViewOnSecondaryContainer,
    tertiary = RuViewTertiary,
    onTertiary = RuViewOnTertiary,
    tertiaryContainer = RuViewTertiaryContainer,
    onTertiaryContainer = RuViewOnTertiaryContainer,
    error = RuViewError,
    onError = RuViewOnError,
    errorContainer = RuViewErrorContainer,
    onErrorContainer = RuViewOnErrorContainer,
    background = RuViewBackground,
    onBackground = RuViewOnBackground,
    surface = RuViewSurface,
    onSurface = RuViewOnSurface,
    surfaceVariant = RuViewSurfaceVariant,
    onSurfaceVariant = RuViewOnSurfaceVariant,
    outline = RuViewOutline
)

@Composable
fun RuViewTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = RuViewDarkColorScheme,
        content = content
    )
}
