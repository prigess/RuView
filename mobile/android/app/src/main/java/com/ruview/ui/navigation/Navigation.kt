package com.ruview.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ruview.ui.screens.DeviceSetupScreen
import com.ruview.ui.screens.NodeHealthScreen
import com.ruview.ui.screens.OccupancyScreen
import com.ruview.ui.screens.SkeletonScreen
import com.ruview.ui.screens.TrainingWizardScreen
import com.ruview.ui.screens.VitalSignsScreen
import com.ruview.ui.screens.ZoneMapScreen
import com.ruview.ui.viewmodel.SensingViewModel

sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    object Setup : Screen("setup", "Setup", Icons.Filled.Settings)
    object Occupancy : Screen("occupancy", "Occupancy", Icons.Filled.Person)
    object Vitals : Screen("vitals", "Vitals", Icons.Filled.FitnessCenter)
    object Skeleton : Screen("skeleton", "Skeleton", Icons.Filled.GridView)
    object Nodes : Screen("nodes", "Nodes", Icons.Filled.Router)
    object Zones : Screen("zones", "Zones", Icons.Filled.Map)
    object Training : Screen("training", "Training", Icons.Filled.School)
}

private val BOTTOM_NAV_ITEMS = listOf(
    Screen.Occupancy,
    Screen.Vitals,
    Screen.Skeleton,
    Screen.Nodes,
    Screen.Zones
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RuViewNavigation(viewModel: SensingViewModel) {
    val navController = rememberNavController()
    val deviceHost by viewModel.deviceHost.collectAsState()
    val isConnected by viewModel.isConnected.collectAsState()

    val startDestination = if (deviceHost.isNotBlank()) {
        Screen.Occupancy.route
    } else {
        Screen.Setup.route
    }

    LaunchedEffect(deviceHost) {
        if (deviceHost.isNotBlank() && !isConnected) {
            viewModel.connect(deviceHost)
        }
    }

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination
    val currentRoute = currentDestination?.route

    val showBottomBar = currentRoute != Screen.Setup.route &&
        currentRoute != Screen.Training.route

    val showTopBar = currentRoute != Screen.Setup.route &&
        currentRoute != Screen.Nodes.route &&
        currentRoute != Screen.Training.route

    Scaffold(
        topBar = {
            if (showTopBar) {
                TopAppBar(
                    title = {
                        Text(
                            text = when (currentRoute) {
                                Screen.Occupancy.route -> "Occupancy"
                                Screen.Vitals.route -> "Vital Signs"
                                Screen.Skeleton.route -> "Pose Skeleton"
                                Screen.Zones.route -> "Zone Map"
                                else -> "RuView"
                            }
                        )
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.surface
                    ),
                    actions = {
                        IconButton(
                            onClick = {
                                navController.navigate(Screen.Training.route) {
                                    launchSingleTop = true
                                }
                            }
                        ) {
                            Icon(
                                imageVector = Icons.Filled.School,
                                contentDescription = "Training Wizard"
                            )
                        }
                        IconButton(
                            onClick = {
                                navController.navigate(Screen.Setup.route) {
                                    launchSingleTop = true
                                }
                            }
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Settings,
                                contentDescription = "Settings / Change Device"
                            )
                        }
                    }
                )
            }
        },
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    BOTTOM_NAV_ITEMS.forEach { screen ->
                        NavigationBarItem(
                            icon = {
                                Icon(
                                    imageVector = screen.icon,
                                    contentDescription = screen.label
                                )
                            },
                            label = { Text(screen.label) },
                            selected = currentDestination?.hierarchy?.any { it.route == screen.route } == true,
                            onClick = {
                                navController.navigate(screen.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            }
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.padding(innerPadding)
        ) {
            composable(Screen.Setup.route) {
                DeviceSetupScreen(
                    viewModel = viewModel,
                    onConnected = {
                        navController.navigate(Screen.Occupancy.route) {
                            popUpTo(Screen.Setup.route) { inclusive = true }
                        }
                    }
                )
            }
            composable(Screen.Occupancy.route) {
                OccupancyScreen(viewModel = viewModel)
            }
            composable(Screen.Vitals.route) {
                VitalSignsScreen(viewModel = viewModel)
            }
            composable(Screen.Skeleton.route) {
                SkeletonScreen(viewModel = viewModel)
            }
            composable(Screen.Nodes.route) {
                NodeHealthScreen(viewModel = viewModel)
            }
            composable(Screen.Zones.route) {
                ZoneMapScreen(viewModel = viewModel)
            }
            composable(Screen.Training.route) {
                TrainingWizardScreen(
                    viewModel = viewModel,
                    onClose = {
                        navController.popBackStack()
                    }
                )
            }
        }
    }
}
