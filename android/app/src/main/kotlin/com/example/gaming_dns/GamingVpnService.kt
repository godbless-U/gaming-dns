package com.example.gaming_dns

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log

class GamingVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.example.gaming_dns.START_VPN"
        const val ACTION_STOP = "com.example.gaming_dns.STOP_VPN"
        const val EXTRA_DNS_IP = "dns_ip"
        private const val TAG = "GamingVpnService"
    }

    private var vpnInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopVpn()
            ACTION_START -> {
                val dnsIp = intent.getStringExtra(EXTRA_DNS_IP)?.trim()
                if (!dnsIp.isNullOrBlank()) startVpn(dnsIp) else stopVpn()
            }
        }
        return START_NOT_STICKY
    }

    private fun startVpn(dnsIp: String) {
        stopInterfaceOnly()

        try {
            val builder = Builder()
                .setSession("Gaming DNS ($dnsIp)")
                .setMtu(1500)
                // اختصاص یک آی‌پی محلی به خود اپلیکیشن
                .addAddress("10.10.10.2", 24)
                
                // اعمال DNS انتخابی شما روی سیستم
                .addDnsServer(dnsIp)
                
                // تکنیک جلوگیری از قطعی اینترنت (Dummy Route Trick):
                // ما به جای اینکه آی‌پی اینترنت را وارد تونل کنیم، یک آی‌پی نامعتبر را روت می‌کنیم.
                // این کار باعث می‌شود اندروید DNS ما را تایید کند، اما ترافیک بازی‌ها و اینترنت 
                // شما را بدون دستکاری از همان وای‌فای یا نت گوشی عبور دهد (بدون افت سرعت).
                .addRoute("10.10.10.3", 32)

            vpnInterface = builder.establish()

            if (vpnInterface == null) {
                Log.e(TAG, "VpnService.Builder.establish() returned null")
                stopSelf()
                return
            }

            Log.i(TAG, "DNS Optimizer successfully applied: $dnsIp")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN", e)
            stopInterfaceOnly()
            stopSelf()
        }
    }

    private fun stopInterfaceOnly() {
        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close VPN interface", e)
        } finally {
            vpnInterface = null
        }
    }

    private fun stopVpn() {
        stopInterfaceOnly()
        stopSelf()
        Log.i(TAG, "DNS Optimizer stopped")
    }

    override fun onDestroy() {
        stopInterfaceOnly()
        super.onDestroy()
    }
}
