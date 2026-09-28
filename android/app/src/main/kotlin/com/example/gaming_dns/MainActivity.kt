package com.example.gaming_dns

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.example.gaming_dns/vpn"
        private const val VPN_REQUEST_CODE = 1001
    }

    private var pendingDnsIp: String? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val dnsIp = call.argument<String>("dns_ip")?.trim()
                        if (dnsIp.isNullOrEmpty()) {
                            result.error("INVALID_DNS", "DNS address is empty", null)
                            return@setMethodCallHandler
                        }
                        pendingDnsIp = dnsIp
                        pendingResult = result
                        requestVpnPermission()
                    }
                    "stopVpn" -> {
                        stopVpnService()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestVpnPermission() {
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
        } else {
            launchVpnService()
        }
    }

    private fun launchVpnService() {
        val dnsIp = pendingDnsIp
        if (dnsIp.isNullOrBlank()) {
            pendingResult?.error("INVALID_DNS", "DNS address is missing", null)
            pendingResult = null
            return
        }

        val intent = Intent(this, GamingVpnService::class.java).apply {
            action = GamingVpnService.ACTION_START
            putExtra(GamingVpnService.EXTRA_DNS_IP, dnsIp)
        }

        startService(intent)
        pendingResult?.success(true)
        pendingResult = null
    }

    private fun stopVpnService() {
        val intent = Intent(this, GamingVpnService::class.java).apply {
            action = GamingVpnService.ACTION_STOP
        }
        startService(intent)
    }

    @Deprecated("Deprecated in Android API; retained for VPN permission compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return

        if (resultCode == Activity.RESULT_OK) {
            launchVpnService()
        } else {
            pendingResult?.error("VPN_PERMISSION_DENIED", "VPN permission was denied", null)
            pendingResult = null
        }
    }

    override fun onDestroy() {
        pendingResult = null
        super.onDestroy()
    }
}
