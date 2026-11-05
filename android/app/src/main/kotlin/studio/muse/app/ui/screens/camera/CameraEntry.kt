package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse

// Entry points of workstream 2 (camera stage, Directed mode, Connections). Minimal stubs: workstream 2 replaces this file
// at merge with the same signatures (plans/suite-ui.md "Entry points for the other workstreams").

/** The Camera stage (Routes.CAMERA_STAGE). */
@Composable
fun CameraStageScreen() {
    val nav = LocalNav.current
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Camera stage", onBack = { nav.back() })
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Camera stage", muse.type.h3, muse.t.ink)
                Tiny("Direct the camera in Blender from your Mac. Coming to the phone soon.")
            }
        }
    }
}

/** The camera bag's Directed · Blender tab. [onApply] gets the Directed CameraSpec as JSON (Claude never spends: only a draft). */
@Composable
fun DirectedModePanel(shotTitle: String, onApply: (cameraJson: String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T("Directed · Blender", muse.type.h3, muse.t.ink)
        Tiny("Plan “$shotTitle” on the Mac camera stage; its guides arrive here to apply.")
    }
}

/** Settings → Connections (owner): Claude & MCP · Blender relay. */
@Composable
fun ConnectionsScreen(onBack: () -> Unit) {
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Connections", onBack = onBack)
            Column(Modifier.padding(16.dp)) { Tiny("Claude & MCP · Blender relay") }
        }
    }
}
