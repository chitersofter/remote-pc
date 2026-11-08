package com.remotepc.remote_pc_app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.remotepc.app/native"
    private val REQ_RECORD_AUDIO = 401
    private val REQ_SPEECH_DIALOG = 402

    private var methodChannel: MethodChannel? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var pendingLang: String = "ru-RU"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    val lang = call.argument<String>("lang") ?: "ru-RU"
                    pendingLang = lang
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(Manifest.permission.RECORD_AUDIO),
                            REQ_RECORD_AUDIO
                        )
                        result.success(mapOf("started" to false, "requestingPermission" to true))
                    } else {
                        startNativeSpeech(lang)
                        result.success(mapOf("started" to true))
                    }
                }
                "stopListening" -> {
                    runOnUiThread {
                        try {
                            speechRecognizer?.stopListening()
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "getLocalSubnets" -> {
                    result.success(detectLocalSubnets())
                }
                "savePref" -> {
                    val key = call.argument<String>("key") ?: ""
                    val value = call.argument<String>("value") ?: ""
                    getSharedPreferences("remote_pc_prefs", Context.MODE_PRIVATE)
                        .edit()
                        .putString(key, value)
                        .apply()
                    result.success(true)
                }
                "getPref" -> {
                    val key = call.argument<String>("key") ?: ""
                    val v = getSharedPreferences("remote_pc_prefs", Context.MODE_PRIVATE)
                        .getString(key, null)
                    result.success(v)
                }
                "vibrate" -> {
                    val ms = (call.argument<Int>("ms") ?: 12).toLong()
                    triggerHaptic(ms)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resetSpeechRecognizer() {
        try {
            speechRecognizer?.cancel()
        } catch (_: Exception) {}
        try {
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
    }

    private fun startNativeSpeech(lang: String) {
        runOnUiThread {
            if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                launchSpeechDialogFallback(lang)
                return@runOnUiThread
            }
            try {
                if (speechRecognizer == null) {
                    speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
                    speechRecognizer?.setRecognitionListener(object : RecognitionListener {
                        override fun onReadyForSpeech(params: Bundle?) {
                            methodChannel?.invokeMethod("onSpeechReady", null)
                        }
                        override fun onBeginningOfSpeech() {}
                        override fun onRmsChanged(rmsdB: Float) {
                            methodChannel?.invokeMethod("onSpeechRms", rmsdB.toDouble())
                        }
                        override fun onBufferReceived(buffer: ByteArray?) {}
                        override fun onEndOfSpeech() {
                            methodChannel?.invokeMethod("onSpeechEnd", null)
                        }
                        override fun onError(error: Int) {
                            if (error == SpeechRecognizer.ERROR_CLIENT ||
                                error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                                error == 11
                            ) {
                                resetSpeechRecognizer()
                            }
                            methodChannel?.invokeMethod("onSpeechError", error)
                        }
                        override fun onResults(results: Bundle?) {
                            val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            val text = list?.firstOrNull() ?: ""
                            methodChannel?.invokeMethod("onSpeechResult", text)
                        }
                        override fun onPartialResults(partialResults: Bundle?) {
                            val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            val text = list?.firstOrNull() ?: ""
                            if (text.isNotBlank()) {
                                methodChannel?.invokeMethod("onSpeechPartial", text)
                            }
                        }
                        override fun onEvent(eventType: Int, params: Bundle?) {}
                    })
                } else {
                    try {
                        speechRecognizer?.cancel()
                    } catch (_: Exception) {}
                }
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                }
                speechRecognizer?.startListening(intent)
            } catch (e: Exception) {
                resetSpeechRecognizer()
                launchSpeechDialogFallback(lang)
            }
        }
    }

    private fun launchSpeechDialogFallback(lang: String) {
        try {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
                putExtra(RecognizerIntent.EXTRA_PROMPT, "Скажите команду для ПК...")
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_SPEECH_DIALOG)
        } catch (_: Exception) {
            methodChannel?.invokeMethod("onSpeechError", -1)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_RECORD_AUDIO) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startNativeSpeech(pendingLang)
            } else {
                methodChannel?.invokeMethod("onSpeechError", SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS)
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_SPEECH_DIALOG) {
            if (resultCode == Activity.RESULT_OK) {
                val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                val text = matches?.firstOrNull() ?: ""
                if (text.isNotBlank()) {
                    methodChannel?.invokeMethod("onSpeechResult", text)
                } else {
                    methodChannel?.invokeMethod("onSpeechError", SpeechRecognizer.ERROR_NO_MATCH)
                }
            } else {
                val code = if (resultCode == Activity.RESULT_CANCELED) -2 else SpeechRecognizer.ERROR_CLIENT
                methodChannel?.invokeMethod("onSpeechError", code)
            }
        }
    }

    private fun detectLocalSubnets(): List<String> {
        val primary = mutableListOf<String>()
        val secondary = mutableListOf<String>()
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                val name = (iface.name ?: "").lowercase()
                val isCellular = name.startsWith("rmnet") ||
                    name.startsWith("ccmni") ||
                    name.startsWith("pdp") ||
                    name.startsWith("clat") ||
                    name.startsWith("dummy")
                if (isCellular) continue

                val isWifiOrLan = name.contains("wlan") ||
                    name.contains("ap") ||
                    name.contains("eth") ||
                    name.contains("rndis")

                val addrs = iface.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        val ip = addr.hostAddress ?: continue
                        val parts = ip.split(".")
                        if (parts.size == 4) {
                            val prefix = "${parts[0]}.${parts[1]}.${parts[2]}"
                            val isPrivateLan = ip.startsWith("192.168.") ||
                                ip.startsWith("172.20.10.") ||
                                ip.startsWith("10.")
                            val target = if (isWifiOrLan || isPrivateLan) primary else secondary
                            if (!primary.contains(prefix) && !secondary.contains(prefix)) {
                                target.add(prefix)
                            }
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return primary + secondary
    }

    private fun triggerHaptic(ms: Long) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    v.vibrate(ms)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        speechRecognizer?.destroy()
        speechRecognizer = null
        super.onDestroy()
    }
}
