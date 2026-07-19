package com.homespotify.stretchpoc

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.abs
import kotlin.math.max
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Pont développeur isolé vers HomeSpotify Stretch Engine.
 *
 * Le plugin ne charge jamais la bibliothèque native lors de son enregistrement.
 * Chaque opération JNI est lancée sur un executor mono-thread créé au premier
 * appel explicite. Le lecteur HomeSpotify et son moteur Media3 ne sont jamais
 * consultés ni modifiés par cette classe.
 */
class HomeSpotifyStretchPocPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executorLock = Any()
    private val libraryLock = Any()
    private val sessions = mutableMapOf<Long, SessionInfo>()

    @Volatile
    private var executor: ExecutorService? = null

    @Volatile
    private var libraryState = LibraryState.NOT_ATTEMPTED

    @Volatile
    private var libraryError: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        check(channel == null) { "HomeSpotify Stretch POC est déjà attaché." }
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null

        val activeExecutor = executor ?: return
        val handles = synchronized(sessions) {
            sessions.keys.toList().also { sessions.clear() }
        }
        if (libraryState == LibraryState.AVAILABLE && handles.isNotEmpty()) {
            try {
                activeExecutor.execute {
                    handles.forEach { handle ->
                        runCatching { NativeBindings.nativeDispose(handle) }
                            .onFailure { error ->
                                Log.w(
                                    LOG_TAG,
                                    "Échec de libération d'un handle POC au detach.",
                                    error,
                                )
                            }
                    }
                }
            } catch (error: RejectedExecutionException) {
                // Le processus Android récupérera la mémoire si l'executor est
                // déjà arrêté. Ne jamais bloquer le thread principal au detach.
                Log.w(LOG_TAG, "Executor POC déjà arrêté au detach.", error)
            }
        }
        activeExecutor.shutdown()
        executor = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> dispatch(result, availabilityProbe = true) {
                ensureNativeLibraryLoaded()
                val probeHandle = NativeBindings.nativeCreate()
                try {
                    val info = decodeEngineInfo(
                        NativeBindings.nativeGetEngineInfo(probeHandle),
                    )
                    if (info["available"] != true) {
                        throw PocException(
                            "NATIVE_LIBRARY_UNAVAILABLE",
                            "Les headers Signalsmith épinglés sont absents du module natif.",
                        )
                    }
                    mapOf(
                        "available" to true,
                        "abi" to currentAbi(),
                        "library" to NATIVE_LIBRARY_NAME,
                    )
                } finally {
                    NativeBindings.nativeDispose(probeHandle)
                }
            }

            "create" -> dispatch(result) {
                ensureNativeLibraryLoaded()
                val handle = NativeBindings.nativeCreate()
                if (handle <= 0L) {
                    throw PocException(
                        "NATIVE_PROCESSING_FAILED",
                        "Le moteur natif n'a pas fourni de handle valide.",
                    )
                }
                synchronized(sessions) {
                    if (sessions.put(handle, SessionInfo()) != null) {
                        NativeBindings.nativeDispose(handle)
                        throw PocException(
                            "NATIVE_PROCESSING_FAILED",
                            "Le registre natif a réutilisé un handle actif.",
                        )
                    }
                }
                handle
            }

            "initialize" -> dispatch(result) {
                val arguments = call.argumentsMap()
                val handle = arguments.requiredHandle()
                val sampleRate = arguments.requiredInt("sampleRate")
                val channels = arguments.requiredInt("channels")
                validateAudioFormat(sampleRate, channels)
                requireSession(handle, initialized = false)
                ensureNativeLibraryLoaded()
                NativeBindings.nativeInitialize(handle, sampleRate, channels)
                synchronized(sessions) {
                    sessions[handle] = SessionInfo(
                        sampleRate = sampleRate,
                        channels = channels,
                        initialized = true,
                    )
                }
                engineInfo(handle)
            }

            "setTempoRatio" -> dispatch(result) {
                val arguments = call.argumentsMap()
                val handle = arguments.requiredHandle()
                val ratio = arguments.requiredDouble("ratio")
                validateRatio(ratio)
                val session = requireSession(handle)
                ensureNativeLibraryLoaded()
                NativeBindings.nativeSetTempoRatio(handle, ratio)
                session.requestedRatio = ratio
                null
            }

            "getRequiredOutputFrames" -> dispatch(result) {
                val arguments = call.argumentsMap()
                val handle = arguments.requiredHandle()
                val inputFrames = arguments.requiredInt("inputFrames")
                validateFrameCount(
                    inputFrames,
                    "inputFrames",
                    MAX_INPUT_FRAMES,
                    allowZero = true,
                )
                requireSession(handle)
                ensureNativeLibraryLoaded()
                NativeBindings.nativeGetRequiredOutputFrames(handle, inputFrames)
            }

            "getAppliedRatio" -> dispatch(result) {
                val handle = call.argumentsMap().requiredHandle()
                requireSession(handle)
                ensureNativeLibraryLoaded()
                mapOf("appliedRatio" to NativeBindings.nativeGetAppliedRatio(handle))
            }

            "getLatencyFrames" -> dispatch(result) {
                val handle = call.argumentsMap().requiredHandle()
                requireSession(handle)
                ensureNativeLibraryLoaded()
                mapOf("latencyFrames" to NativeBindings.nativeGetLatencyFrames(handle))
            }

            "getEngineInfo" -> dispatch(result) {
                val handle = call.argumentsMap().requiredHandle()
                requireSession(handle)
                ensureNativeLibraryLoaded()
                engineInfo(handle)
            }

            "processPcm" -> dispatch(result) {
                processPcm(call.argumentsMap())
            }

            "flush" -> dispatch(result) {
                flush(call.argumentsMap())
            }

            "reset" -> dispatch(result) {
                val handle = call.argumentsMap().requiredHandle()
                val session = requireSession(handle)
                ensureNativeLibraryLoaded()
                NativeBindings.nativeReset(handle)
                session.requestedRatio = 1.0
                null
            }

            "dispose" -> dispatch(result) {
                val handle = call.argumentsMap().requiredHandle()
                val session = synchronized(sessions) { sessions[handle] }
                if (session != null) {
                    ensureNativeLibraryLoaded()
                    NativeBindings.nativeDispose(handle)
                    synchronized(sessions) { sessions.remove(handle) }
                }
                null
            }

            else -> result.notImplemented()
        }
    }

    private fun processPcm(arguments: Map<*, *>): Map<String, Any?> {
        val handle = arguments.requiredHandle()
        val session = requireSession(handle)
        val inputFrames = arguments.requiredInt("inputFrames")
        val outputCapacityFrames = arguments.requiredInt("outputCapacityFrames")
        val input = arguments["input"] as? FloatArray
            ?: throw PocException(
                "INVALID_ARGUMENT",
                "input doit être un buffer Float32.",
            )
        validateFrameCount(inputFrames, "inputFrames", MAX_INPUT_FRAMES)
        if (inputFrames < MIN_PROCESS_FRAMES) {
            throw PocException(
                "INVALID_ARGUMENT",
                "inputFrames doit contenir au moins $MIN_PROCESS_FRAMES frames.",
            )
        }
        validateFrameCount(
            outputCapacityFrames,
            "outputCapacityFrames",
            MAX_OUTPUT_FRAMES,
        )
        validateInputBuffer(input, inputFrames, session.channels)
        ensureNativeLibraryLoaded()

        val requiredFrames =
            NativeBindings.nativeGetRequiredOutputFrames(handle, inputFrames)
        if (requiredFrames <= 0 || requiredFrames > MAX_OUTPUT_FRAMES) {
            throw PocException(
                "NATIVE_PROCESSING_FAILED",
                "La capacité calculée par le moteur natif est invalide.",
                mapOf("requiredOutputFrames" to requiredFrames),
            )
        }
        if (outputCapacityFrames < requiredFrames) {
            throw PocException(
                "BUFFER_TOO_SMALL",
                "La capacité de sortie est insuffisante.",
                mapOf(
                    "requiredOutputFrames" to requiredFrames,
                    "outputCapacityFrames" to outputCapacityFrames,
                ),
            )
        }

        val inputStats = measureSamples(input)
        val startedAt = SystemClock.elapsedRealtimeNanos()
        val output = NativeBindings.nativeProcess(
            handle,
            input,
            inputFrames,
            outputCapacityFrames,
        )
        val processingNanos = max(1L, SystemClock.elapsedRealtimeNanos() - startedAt)
        validateNativeOutput(output, outputCapacityFrames, session.channels)
        val outputFrames = output.size / session.channels
        val outputStats = measureSamples(output)
        val appliedRatio = NativeBindings.nativeGetAppliedRatio(handle)
        val engineInfo = engineInfo(handle)

        return mapOf(
            "output" to output,
            "metrics" to mapOf(
                "requestedRatio" to session.requestedRatio,
                "appliedRatio" to appliedRatio,
                "sampleRate" to session.sampleRate,
                "channels" to session.channels,
                "inputFrames" to inputFrames,
                "outputFrames" to outputFrames,
                "processingMicros" to processingNanos / 1_000L,
                "realtimeFactor" to realtimeFactor(
                    inputFrames,
                    session.sampleRate,
                    processingNanos,
                ),
                "latencyFrames" to NativeBindings.nativeGetLatencyFrames(handle),
                "inputPeak" to inputStats.peak,
                "outputPeak" to outputStats.peak,
                "outOfRangeSamples" to outputStats.overRangeCount,
                "inputOverRangeSamples" to inputStats.overRangeCount,
                "outputOverRangeSamples" to outputStats.overRangeCount,
                "profile" to (engineInfo["profile"] ?: "UNKNOWN"),
                "engineName" to (engineInfo["engineName"] ?: "HomeSpotify Stretch Engine"),
            ),
        )
    }

    private fun flush(arguments: Map<*, *>): Map<String, Any?> {
        val handle = arguments.requiredHandle()
        val session = requireSession(handle)
        val outputCapacityFrames = arguments.requiredInt("outputCapacityFrames")
        validateFrameCount(
            outputCapacityFrames,
            "outputCapacityFrames",
            MAX_OUTPUT_FRAMES,
        )
        ensureNativeLibraryLoaded()

        val startedAt = SystemClock.elapsedRealtimeNanos()
        val output = NativeBindings.nativeFlush(handle, outputCapacityFrames)
        val processingNanos = max(1L, SystemClock.elapsedRealtimeNanos() - startedAt)
        validateNativeOutput(output, outputCapacityFrames, session.channels)
        val outputStats = measureSamples(output)
        val engineInfo = engineInfo(handle)

        return mapOf(
            "output" to output,
            "metrics" to mapOf(
                "requestedRatio" to session.requestedRatio,
                "appliedRatio" to NativeBindings.nativeGetAppliedRatio(handle),
                "sampleRate" to session.sampleRate,
                "channels" to session.channels,
                "inputFrames" to 0,
                "outputFrames" to output.size / session.channels,
                "processingMicros" to processingNanos / 1_000L,
                "realtimeFactor" to 0.0,
                "latencyFrames" to NativeBindings.nativeGetLatencyFrames(handle),
                "inputPeak" to 0.0,
                "outputPeak" to outputStats.peak,
                "outOfRangeSamples" to outputStats.overRangeCount,
                "inputOverRangeSamples" to 0,
                "outputOverRangeSamples" to outputStats.overRangeCount,
                "profile" to (engineInfo["profile"] ?: "UNKNOWN"),
                "engineName" to (engineInfo["engineName"] ?: "HomeSpotify Stretch Engine"),
            ),
        )
    }

    private fun engineInfo(handle: Long): Map<String, Any?> {
        val session = requireSession(handle)
        val decoded = decodeEngineInfo(NativeBindings.nativeGetEngineInfo(handle))
        val totalLatency = NativeBindings.nativeGetLatencyFrames(handle)
        decoded["initialized"] = session.initialized
        decoded["sampleRate"] = session.sampleRate
        decoded["channels"] = session.channels
        decoded["appliedRatio"] = NativeBindings.nativeGetAppliedRatio(handle)
        decoded["targetRatio"] = session.requestedRatio
        decoded.putIfAbsent("engineName", "HomeSpotify Stretch Engine")
        decoded.putIfAbsent("profile", "UNKNOWN")
        decoded.putIfAbsent("inputLatencyFrames", 0)
        decoded.putIfAbsent("outputLatencyFrames", totalLatency)
        return decoded
    }

    private fun decodeEngineInfo(rawJson: String): MutableMap<String, Any?> {
        try {
            return jsonObjectToMap(JSONObject(rawJson))
        } catch (error: JSONException) {
            throw PocException(
                "NATIVE_PROCESSING_FAILED",
                "Les informations du moteur natif sont invalides.",
                mapOf("type" to error.javaClass.simpleName),
            )
        }
    }

    private fun jsonObjectToMap(value: JSONObject): MutableMap<String, Any?> {
        val result = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = jsonValue(value.opt(key))
        }
        return result
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> List(value.length()) { index -> jsonValue(value.opt(index)) }
        is Boolean, is Number, is String -> value
        else -> value.toString()
    }

    private fun dispatch(
        result: MethodChannel.Result,
        availabilityProbe: Boolean = false,
        operation: () -> Any?,
    ) {
        val activeExecutor = try {
            processingExecutor()
        } catch (error: PocException) {
            postError(result, error)
            return
        }
        try {
            activeExecutor.execute {
                try {
                    postSuccess(result, operation())
                } catch (error: PocException) {
                    if (availabilityProbe) {
                        postSuccess(
                            result,
                            mapOf(
                                "available" to false,
                                "abi" to currentAbi(),
                                "errorCode" to error.code,
                                "error" to error.message,
                            ),
                        )
                    } else {
                        postError(result, error)
                    }
                } catch (error: IllegalArgumentException) {
                    postError(result, nativeException(error, "INVALID_ARGUMENT"))
                } catch (error: IndexOutOfBoundsException) {
                    postError(result, nativeException(error, "BUFFER_TOO_SMALL"))
                } catch (error: IllegalStateException) {
                    postError(result, nativeException(error, "NOT_INITIALIZED"))
                } catch (error: OutOfMemoryError) {
                    postError(
                        result,
                        PocException(
                            "NATIVE_PROCESSING_FAILED",
                            "Mémoire insuffisante pour le buffer PCM du POC.",
                            mapOf("type" to error.javaClass.simpleName),
                        ),
                    )
                } catch (error: LinkageError) {
                    val unavailable = nativeUnavailable(error)
                    if (availabilityProbe) {
                        postSuccess(
                            result,
                            mapOf(
                                "available" to false,
                                "abi" to currentAbi(),
                                "errorCode" to unavailable.code,
                                "error" to unavailable.message,
                            ),
                        )
                    } else {
                        postError(result, unavailable)
                    }
                } catch (error: Exception) {
                    postError(
                        result,
                        PocException(
                            "NATIVE_PROCESSING_FAILED",
                            error.message ?: "Le moteur natif a rejeté l'opération.",
                            mapOf("type" to error.javaClass.simpleName),
                        ),
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            postError(
                result,
                PocException(
                    "NATIVE_PROCESSING_FAILED",
                    "L'executor du POC est arrêté.",
                ),
            )
        }
    }

    private fun processingExecutor(): ExecutorService {
        executor?.let { return it }
        return synchronized(executorLock) {
            executor ?: Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "homespotify-stretch-poc").apply {
                    isDaemon = true
                }
            }.also { executor = it }
        }
    }

    private fun ensureNativeLibraryLoaded() {
        if (libraryState == LibraryState.AVAILABLE) return
        synchronized(libraryLock) {
            when (libraryState) {
                LibraryState.AVAILABLE -> return
                LibraryState.UNAVAILABLE -> throw PocException(
                    "NATIVE_LIBRARY_UNAVAILABLE",
                    libraryError ?: "Bibliothèque native indisponible.",
                )

                LibraryState.NOT_ATTEMPTED -> {
                    try {
                        System.loadLibrary(NATIVE_LIBRARY_NAME)
                        libraryState = LibraryState.AVAILABLE
                        libraryError = null
                    } catch (error: LinkageError) {
                        val failure = nativeUnavailable(error)
                        libraryState = LibraryState.UNAVAILABLE
                        libraryError = failure.message
                        throw failure
                    }
                }
            }
        }
    }

    private fun nativeUnavailable(error: LinkageError): PocException =
        PocException(
            "NATIVE_LIBRARY_UNAVAILABLE",
            "HomeSpotify Stretch n'est pas disponible pour ${currentAbi()}.",
            mapOf("type" to error.javaClass.simpleName),
        )

    private fun nativeException(error: RuntimeException, fallbackCode: String): PocException {
        val message = error.message ?: "Le moteur natif a rejeté l'opération."
        val separator = message.indexOf(':')
        val candidateCode = if (separator > 0) message.substring(0, separator) else ""
        val knownCodes = setOf(
            "NATIVE_LIBRARY_UNAVAILABLE",
            "INVALID_ARGUMENT",
            "UNSUPPORTED_FORMAT",
            "NOT_INITIALIZED",
            "BUFFER_TOO_SMALL",
            "DISPOSED",
            "NATIVE_PROCESSING_FAILED",
        )
        return PocException(
            if (candidateCode in knownCodes) candidateCode else fallbackCode,
            message,
            mapOf("type" to error.javaClass.simpleName),
        )
    }

    private fun requireSession(handle: Long, initialized: Boolean = true): SessionInfo {
        val session = synchronized(sessions) { sessions[handle] }
            ?: throw PocException(
                "DISPOSED",
                "Le handle du moteur est inconnu ou déjà libéré.",
            )
        if (initialized && !session.initialized) {
            throw PocException(
                "NOT_INITIALIZED",
                "Le moteur doit être initialisé avant cette opération.",
            )
        }
        return session
    }

    private fun validateAudioFormat(sampleRate: Int, channels: Int) {
        if (sampleRate !in MIN_SAMPLE_RATE..MAX_SAMPLE_RATE) {
            throw PocException(
                "UNSUPPORTED_FORMAT",
                "La fréquence doit être comprise entre $MIN_SAMPLE_RATE et $MAX_SAMPLE_RATE Hz.",
            )
        }
        if (channels !in 1..2) {
            throw PocException(
                "UNSUPPORTED_FORMAT",
                "Seuls les buffers PCM mono et stéréo sont acceptés.",
            )
        }
    }

    private fun validateRatio(ratio: Double) {
        if (!ratio.isFinite() || ratio < MIN_RATIO || ratio > MAX_RATIO) {
            throw PocException(
                "INVALID_ARGUMENT",
                "Le ratio doit être compris entre 0.70 et 1.30.",
            )
        }
    }

    private fun validateFrameCount(
        value: Int,
        name: String,
        maximum: Int,
        allowZero: Boolean = false,
    ) {
        val minimum = if (allowZero) 0 else 1
        if (value < minimum || value > maximum) {
            throw PocException(
                "INVALID_ARGUMENT",
                "$name doit être compris entre $minimum et $maximum.",
            )
        }
    }

    private fun validateInputBuffer(input: FloatArray, frames: Int, channels: Int) {
        val expectedSamples = frames.toLong() * channels.toLong()
        if (expectedSamples > Int.MAX_VALUE || input.size.toLong() != expectedSamples) {
            throw PocException(
                "INVALID_ARGUMENT",
                "La taille PCM ne correspond pas à inputFrames × channels.",
                mapOf(
                    "expectedSamples" to expectedSamples,
                    "actualSamples" to input.size,
                ),
            )
        }
        input.forEach { sample ->
            if (!sample.isFinite()) {
                throw PocException(
                    "INVALID_ARGUMENT",
                    "Le buffer PCM contient une valeur non finie.",
                )
            }
        }
    }

    private fun validateNativeOutput(
        output: FloatArray,
        outputCapacityFrames: Int,
        channels: Int,
    ) {
        if (output.size % channels != 0) {
            throw PocException(
                "NATIVE_PROCESSING_FAILED",
                "Le moteur a renvoyé un buffer non aligné sur les canaux.",
            )
        }
        val outputFrames = output.size / channels
        if (outputFrames > outputCapacityFrames) {
            throw PocException(
                "NATIVE_PROCESSING_FAILED",
                "Le moteur a dépassé la capacité de sortie annoncée.",
            )
        }
        output.forEach { sample ->
            if (!sample.isFinite()) {
                throw PocException(
                    "NATIVE_PROCESSING_FAILED",
                    "Le moteur a renvoyé une valeur PCM non finie.",
                )
            }
        }
    }

    private fun measureSamples(samples: FloatArray): SampleStats {
        var peak = 0.0
        var overRangeCount = 0
        samples.forEach { sample ->
            val absolute = abs(sample.toDouble())
            peak = max(peak, absolute)
            if (absolute > 1.0) overRangeCount++
        }
        return SampleStats(peak = peak, overRangeCount = overRangeCount)
    }

    private fun realtimeFactor(
        inputFrames: Int,
        sampleRate: Int,
        processingNanos: Long,
    ): Double {
        val sourceSeconds = inputFrames.toDouble() / sampleRate.toDouble()
        val processingSeconds = processingNanos.toDouble() / 1_000_000_000.0
        return sourceSeconds / processingSeconds
    }

    private fun currentAbi(): String =
        Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, error: PocException) {
        mainHandler.post {
            result.error(error.code, error.message, error.details)
        }
    }

    private fun MethodCall.argumentsMap(): Map<*, *> =
        arguments as? Map<*, *>
            ?: throw PocException(
                "INVALID_ARGUMENT",
                "Les arguments doivent être une map.",
            )

    private fun Map<*, *>.requiredHandle(): Long {
        val handle = (this["handle"] as? Number)?.toLong()
            ?: throw PocException("INVALID_ARGUMENT", "handle est obligatoire.")
        if (handle <= 0L) {
            throw PocException("INVALID_ARGUMENT", "handle doit être positif.")
        }
        return handle
    }

    private fun Map<*, *>.requiredInt(name: String): Int {
        val value = (this[name] as? Number)?.toLong()
            ?: throw PocException("INVALID_ARGUMENT", "$name est obligatoire.")
        if (value !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
            throw PocException("INVALID_ARGUMENT", "$name dépasse la plage entière.")
        }
        return value.toInt()
    }

    private fun Map<*, *>.requiredDouble(name: String): Double =
        (this[name] as? Number)?.toDouble()
            ?: throw PocException("INVALID_ARGUMENT", "$name est obligatoire.")

    private data class SessionInfo(
        val sampleRate: Int = 0,
        val channels: Int = 0,
        val initialized: Boolean = false,
        var requestedRatio: Double = 1.0,
    )

    private data class SampleStats(
        val peak: Double,
        val overRangeCount: Int,
    )

    private data class PocException(
        val code: String,
        override val message: String,
        val details: Any? = null,
    ) : RuntimeException(message)

    private enum class LibraryState {
        NOT_ATTEMPTED,
        AVAILABLE,
        UNAVAILABLE,
    }

    private object NativeBindings {
        external fun nativeCreate(): Long

        external fun nativeInitialize(handle: Long, sampleRate: Int, channels: Int)

        external fun nativeSetTempoRatio(handle: Long, ratio: Double)

        external fun nativeProcess(
            handle: Long,
            input: FloatArray,
            inputFrames: Int,
            outputCapacityFrames: Int,
        ): FloatArray

        external fun nativeFlush(handle: Long, outputCapacityFrames: Int): FloatArray

        external fun nativeReset(handle: Long)

        external fun nativeGetLatencyFrames(handle: Long): Int

        external fun nativeGetRequiredOutputFrames(handle: Long, inputFrames: Int): Int

        external fun nativeGetAppliedRatio(handle: Long): Double

        external fun nativeGetEngineInfo(handle: Long): String

        external fun nativeDispose(handle: Long)
    }

    private companion object {
        const val CHANNEL_NAME = "com.homespotify/stretch_poc"
        const val LOG_TAG = "HomeSpotifyStretchPoc"
        const val NATIVE_LIBRARY_NAME = "homespotify_stretch_poc"
        const val MIN_SAMPLE_RATE = 8_000
        const val MAX_SAMPLE_RATE = 192_000
        const val MIN_RATIO = 0.70
        const val MAX_RATIO = 1.30
        const val MAX_INPUT_FRAMES = 480_000
        const val MIN_PROCESS_FRAMES = 2
        const val MAX_OUTPUT_FRAMES = 2_097_152
    }
}
