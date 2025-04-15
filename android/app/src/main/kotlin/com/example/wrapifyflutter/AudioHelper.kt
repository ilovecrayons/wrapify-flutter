package com.example.wrapifyflutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioHelper(private val context: Context) {
    private val audioManager: AudioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setAudioFocus" -> {
                try {
                    val contentType = call.argument<String>("contentType")
                    val usage = call.argument<String>("usage")
                    val bufferSize = call.argument<Int>("bufferSize") ?: 4096
                    
                    setAudioFocus(contentType, usage, bufferSize)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("AUDIO_FOCUS_ERROR", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
    
    private fun setAudioFocus(contentType: String?, usage: String?, bufferSize: Int) {
        // Set audio focus request for Android O and higher
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audioAttributes = AudioAttributes.Builder()
                .setContentType(getContentType(contentType))
                .setUsage(getUsage(usage))
                .build()
                
            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(audioAttributes)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener { }
                .build()
                
            audioManager.requestAudioFocus(focusRequest)
        } else {
            // Legacy approach for older Android versions
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC, 
                AudioManager.AUDIOFOCUS_GAIN)
        }
        
        // Set system volume to 100% for music stream
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxVolume, 0)
    }
    
    private fun getContentType(contentType: String?): Int {
        return when (contentType) {
            "music" -> AudioAttributes.CONTENT_TYPE_MUSIC
            "speech" -> AudioAttributes.CONTENT_TYPE_SPEECH
            else -> AudioAttributes.CONTENT_TYPE_MUSIC
        }
    }
    
    private fun getUsage(usage: String?): Int {
        return when (usage) {
            "media" -> AudioAttributes.USAGE_MEDIA
            "game" -> AudioAttributes.USAGE_GAME
            else -> AudioAttributes.USAGE_MEDIA
        }
    }
}
