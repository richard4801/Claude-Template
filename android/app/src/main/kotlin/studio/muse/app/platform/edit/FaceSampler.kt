package studio.muse.app.platform.edit

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import studio.muse.core.edit.Reframe
import java.io.File
import kotlin.coroutines.resume

/**
 * Auto reframe on the phone: frames of a clip's source at the sample times, each through ML Kit face detection (fast
 * mode, the Play Services model), as [Reframe.Sample]s in clip-local time. Frames are read at 480 px on the long side.
 */
object FaceSampler {
    private val detector by lazy {
        FaceDetection.getClient(FaceDetectorOptions.Builder().setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST).setMinFaceSize(0.08f).build())
    }

    /**
     * [times] are clip-local seconds; [sourceAt] maps one to the source's seconds (speed and curves). [onProgress] gets
     * 0–1. Frames that fail to decode count as "no face" (the path holds there).
     */
    suspend fun sample(file: File, times: List<Double>, sourceAt: (Double) -> Double, onProgress: (Float) -> Unit = {}): List<Reframe.Sample> = withContext(Dispatchers.Default) {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(file.absolutePath)
            times.mapIndexed { i, t ->
                val us = (sourceAt(t) * 1_000_000).toLong()
                val frame: Bitmap? = runCatching { mmr.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, 480, 480) }.getOrNull()
                val faces = frame?.let { detect(it) }.orEmpty()
                frame?.recycle()
                onProgress((i + 1f) / times.size)
                Reframe.Sample(t, faces)
            }
        } finally { mmr.release() }
    }

    private suspend fun detect(bmp: Bitmap): List<Reframe.Face> = suspendCancellableCoroutine { cont ->
        detector.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { faces ->
                cont.resume(faces.map { f ->
                    val b = f.boundingBox
                    Reframe.Face(b.exactCenterX() / bmp.width.toDouble(), b.exactCenterY() / bmp.height.toDouble(), b.width() / bmp.width.toDouble(), b.height() / bmp.height.toDouble())
                })
            }
            .addOnFailureListener { cont.resume(emptyList()) }
    }
}
