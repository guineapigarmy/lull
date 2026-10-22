package com.rohankanjani.lull

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.rohankanjani.lull.bedjetkit.BedJetDiscovery
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.NearbyBedJet

/** Finds real BedJets over Bluetooth, without connecting to any of them. Runs on the main thread. */
@SuppressLint("MissingPermission") // Every Bluetooth call is behind hasPermissions().
class BleDiscovery(context: Context) : BedJetDiscovery {
    private val context = context.applicationContext
    private val adapter: BluetoothAdapter? = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val main = Handler(Looper.getMainLooper())

    override var nearby: List<NearbyBedJet> = emptyList()
        private set(value) {
            if (field == value) return
            field = value
            onChange?.invoke()
        }
    override var state: LinkState = LinkState.SEARCHING
        private set(value) {
            if (field == value) return
            field = value
            onChange?.invoke()
        }
    override var onChange: (() -> Unit)? = null

    private var wantsScan = false
    private var scanning: ScanCallback? = null
    private var radioReceiver: BroadcastReceiver? = null

    override fun start() {
        wantsScan = true
        watchRadio()
        scan()
    }

    override fun stop() {
        wantsScan = false
        stopScan()
        radioReceiver?.let(context::unregisterReceiver)
        radioReceiver = null
        nearby = emptyList()
    }

    private fun hasPermissions(): Boolean = listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        .all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    private fun scan() {
        val adapter = adapter
        state = when {
            adapter == null -> LinkState.BLUETOOTH_OFF
            !hasPermissions() -> LinkState.UNAUTHORIZED
            !adapter.isEnabled -> LinkState.BLUETOOTH_OFF
            else -> LinkState.SEARCHING
        }
        if (!wantsScan || state != LinkState.SEARCHING || scanning != null) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post { if (scanning === this) found(result) }
            }

            override fun onScanFailed(errorCode: Int) {
                // Android limits how often an app may start scanning; try again shortly.
                main.postDelayed({
                    if (scanning !== this) return@postDelayed
                    scanning = null
                    scan()
                }, 5_000)
            }
        }
        scanning = callback
        // Not filtered by service, because a V2 is known by its name. Every report keeps the signal current.
        scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
    }

    private fun found(result: ScanResult) {
        if (!wantsScan || !BleLink.isBedJet(result)) return
        val id = result.device.address
        val name = result.scanRecord?.deviceName ?: result.device.name ?: "BedJet"
        val unit = NearbyBedJet(id, name, BleLink.generation(result), result.rssi)
        val index = nearby.indexOfFirst { it.id == id }
        nearby = if (index >= 0) nearby.toMutableList().also { it[index] = unit } else nearby + unit
    }

    private fun stopScan() {
        val callback = scanning ?: return
        scanning = null
        if (hasPermissions() && adapter?.isEnabled == true) adapter.bluetoothLeScanner?.stopScan(callback)
    }

    private fun watchRadio() {
        if (radioReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_ON -> scan()
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        scanning = null
                        nearby = emptyList()
                        state = LinkState.BLUETOOTH_OFF
                    }
                }
            }
        }
        radioReceiver = receiver
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }
}
