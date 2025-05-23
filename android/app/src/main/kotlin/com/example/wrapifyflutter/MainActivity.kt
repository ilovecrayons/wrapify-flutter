package com.example.wrapifyflutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

// Changed from FlutterActivity to AudioServiceActivity for background audio support
class MainActivity: AudioServiceActivity() {
    private val CHANNEL = "com.example.wrapifyflutter/audio"
    private lateinit var audioHelper: AudioHelper
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        audioHelper = AudioHelper(context)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            audioHelper.handleMethodCall(call, result)
        }
    }
}
