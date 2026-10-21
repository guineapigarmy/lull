package com.rohankanjani.lull

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.rohankanjani.lull.bedjetkit.BedJetError
import com.rohankanjani.lull.bedjetkit.BedJetLink
import com.rohankanjani.lull.bedjetkit.Codec
import com.rohankanjani.lull.bedjetkit.ConnectionTiming
import com.rohankanjani.lull.bedjetkit.DeviceStatus
import com.rohankanjani.lull.bedjetkit.Handoff
import com.rohankanjani.lull.bedjetkit.LinkState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/**
 * Android Bluetooth transport for a BedJet 3. Connects to the remembered unit, or the first one found.
 * Everything runs on the main thread; Bluetooth callbacks are posted there.
 *
 * The BedJet accepts a single connection and stops advertising while it has one, so a second phone
 * cannot even see it. Two phones share it by handing over: the phone that wants the BedJet briefly
 * advertises a request, and the phone holding it disconnects when it sees that request. Requests use
 * the same UUIDs as the iOS app, so iPhones and Android phones hand over to each other.
 */
@SuppressLint("MissingPermission") // Every Bluetooth call is behind hasPermissions().
class BleLink(context: Context) : BedJetLink {
    private val context = context.applicationContext

    override var state: LinkState = LinkState.SEARCHING
        private set(value) {
            if (field == value) return
            field = value
            if (value == LinkState.READY) stopRequesting()
            onStateChange?.invoke(value)
        }
    override var onStateChange: ((LinkState) -> Unit)? = null
    override var onStatus: ((DeviceStatus) -> Unit)? = null
    /** Return false to postpone a hand-over, for example while a schedule is being saved. */
    var canYield: () -> Boolean = { true }
    var lastConnection: ConnectionTiming? = null
        private set

    private companion object {
        fun uuid(short: String): UUID = UUID.fromString("0000$short-BED0-0080-AA55-4265644A6574")
        val SERVICE: UUID = uuid("1000")
        val STATUS: UUID = uuid("2000")
        val NAME: UUID = uuid("2001")
        val COMMAND: UUID = uuid("2004")
        val REPLY: UUID = uuid("2006")
        val CLIENT_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val REMEMBERED_KEY = "peripheral"
        const val NAME_KEY = "deviceName"

        /** How long a phone that handed over stays out of the way before it quietly waits for the BedJet again. */
        const val COURTESY_MS = 10_000L
        /** How long a request is advertised. Shorter than the courtesy, so one request is answered once. */
        const val REQUEST_DURATION_MS = 8_000L
        const val OPERATION_TIMEOUT_MS = 5_000L
    }

    private val prefs = context.getSharedPreferences("BedJetKit", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val adapter: BluetoothAdapter? = context.getSystemService(BluetoothManager::class.java)?.adapter

    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null
    private var reply: BluetoothGattCharacteristic? = null
    private var statusCharacteristic: BluetoothGattCharacteristic? = null
    private var wantsConnection = false
    private var yieldedUntil = 0L
    private var requestGeneration = 0
    private var advertising: AdvertiseCallback? = null
    private var scanning: ScanCallback? = null
    private var receiverRegistered = false
    /** A direct connection to the remembered unit gives up after about 30 seconds; after that, wait for it. */
    private var directFailed = false
    private var askedAt: Long? = null
    private var linkUpAfter: Double? = null
    private var radioOnAfter = 0.0
    private var servicesAfter = 0.0
    private var foundByScan = false

    private var lastHead: ByteArray? = null
    private var lastRemainderRead = 0L
    private var lastExtra: DeviceStatus.Extra? = null
    private var tag = 0
    private val serial = Mutex()

    // Android runs one GATT operation at a time, so everything sent to the unit waits its turn here.
    private class Operation(val begin: (BluetoothGatt) -> Boolean, val finish: (ByteArray?, Int) -> Unit)

    private val operations = ArrayDeque<Operation>()
    private var current: Operation? = null

    override fun start() {
        requestControl()
    }

    override fun stop() {
        wantsConnection = false
        askedAt = null
        stopRequesting()
        stopScan()
        yieldedUntil = 0
        val gatt = gatt ?: return
        if (state == LinkState.READY) {
            gatt.disconnect()
        } else {
            // Nothing is connected, so no disconnect will arrive to tidy up.
            gatt.close()
            this.gatt = null
            if (state == LinkState.CONNECTING || state == LinkState.YIELDED) state = LinkState.SEARCHING
        }
    }

    override fun requestControl() {
        wantsConnection = true
        watchRadio()
        if (state == LinkState.YIELDED) {
            yieldedUntil = 0
            // A phone that handed over waits quietly for the BedJet; asking for it again goes straight to it.
            gatt?.close()
            gatt = null
            directFailed = false
            state = LinkState.SEARCHING
        }
        if (state != LinkState.READY && askedAt == null) {
            askedAt = SystemClock.elapsedRealtime()
            radioOnAfter = 0.0
        }
        if (!radioUsable()) return
        connectIfPossible()
        if (state == LinkState.READY) return
        val request = handoffUuid ?: return
        // Ask straight away rather than waiting to see whether the BedJet answers: if it is free
        // nobody is listening, and if another phone has it every moment of waiting is wasted.
        requestGeneration += 1
        val generation = requestGeneration
        advertise(request)
        main.postDelayed({ if (requestGeneration == generation) stopRequesting() }, REQUEST_DURATION_MS)
    }

    /** Forgets the remembered unit so the next start pairs with whichever BedJet is nearest. */
    fun forget() {
        prefs.edit().remove(REMEMBERED_KEY).remove(NAME_KEY).apply()
        directFailed = false
        gatt?.disconnect()
    }

    override suspend fun send(command: ByteArray) {
        serial.withLock { write(command) }
    }

    override suspend fun query(request: Int): ByteArray = serial.withLock {
        // The reply characteristic keeps its previous contents until the unit has answered,
        // so retry until the echoed request and tag match.
        repeat(4) { attempt ->
            tag = if (tag == 255) 1 else tag + 1
            write(Codec.query(request, tag))
            if (attempt > 0) delay(150)
            val data = read()
            if (data.size >= 2 && data[0].toInt() and 0xff == request && data[1].toInt() and 0xff == tag) {
                return@withLock data.copyOfRange(2, data.size)
            }
        }
        throw BedJetError.BadResponse
    }

    // Radio and permission

    private fun hasPermissions(): Boolean = listOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
    ).all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    /** Reports why Bluetooth can't be used right now, and returns whether it can. */
    private fun radioUsable(): Boolean {
        val adapter = adapter
        return when {
            adapter == null -> { state = LinkState.BLUETOOTH_OFF; false }
            !hasPermissions() -> { state = LinkState.UNAUTHORIZED; false }
            !adapter.isEnabled -> { state = LinkState.BLUETOOTH_OFF; false }
            else -> {
                if (state == LinkState.BLUETOOTH_OFF || state == LinkState.UNAUTHORIZED) state = LinkState.SEARCHING
                true
            }
        }
    }

    private fun watchRadio() {
        if (receiverRegistered) return
        receiverRegistered = true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_ON -> {
                        radioOnAfter = askedAt?.let { seconds(it) } ?: 0.0
                        if (wantsConnection && radioUsable()) connectIfPossible()
                    }
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        gatt?.close()
                        dropConnection(reconnect = false)
                        state = LinkState.BLUETOOTH_OFF
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    // Connection

    private fun connectIfPossible() {
        if (!wantsConnection || gatt != null || !radioUsable()) return
        if (state == LinkState.YIELDED && SystemClock.elapsedRealtime() < yieldedUntil) return
        val adapter = adapter ?: return
        val remembered = prefs.getString(REMEMBERED_KEY, null)
        if (remembered != null && BluetoothAdapter.checkBluetoothAddress(remembered)) {
            // Going straight to the unit this phone already knows is several times quicker than scanning for it.
            foundByScan = false
            connect(adapter.getRemoteDevice(remembered))
        } else {
            if (state != LinkState.YIELDED) state = LinkState.SEARCHING
            foundByScan = true
            startScan(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build(), forRequests = false)
        }
    }

    private fun connect(device: BluetoothDevice) {
        stopScan()
        // A phone that handed over keeps saying so while it waits; the connection completes
        // whenever the BedJet becomes free again. So does a phone whose quick attempt timed out,
        // most likely because another phone has the BedJet.
        val waits = state == LinkState.YIELDED || directFailed
        if (state != LinkState.YIELDED) state = LinkState.CONNECTING
        @Suppress("DEPRECATION") // The replacement needs Android 17; this works on every version Lull supports.
        gatt = device.connectGatt(context, waits, callback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun dropConnection(reconnect: Boolean = true) {
        gatt = null
        command = null
        reply = null
        statusCharacteristic = null
        lastHead = null
        lastExtra = null
        current?.finish?.invoke(null, BluetoothGatt.GATT_FAILURE)
        current = null
        while (operations.isNotEmpty()) operations.removeFirst().finish(null, BluetoothGatt.GATT_FAILURE)
        stopScan()
        if (state != LinkState.YIELDED && state != LinkState.BLUETOOTH_OFF) state = LinkState.SEARCHING
        // A short pause stops a unit that keeps refusing from turning this into a busy loop.
        if (reconnect) main.postDelayed({ connectIfPossible() }, 500)
    }

    // Hand-over between phones

    private val handoffUuid: UUID?
        get() = prefs.getString(NAME_KEY, null)?.let(Handoff::uuid)

    private fun advertise(request: UUID) {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        advertising?.let { advertiser.stopAdvertising(it) }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(request)).setIncludeDeviceName(false).build()
        val callback = object : AdvertiseCallback() {}
        advertising = callback
        advertiser.startAdvertising(settings, data, callback)
    }

    private fun stopRequesting() {
        requestGeneration += 1
        val callback = advertising ?: return
        advertising = null
        if (hasPermissions()) adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback)
    }

    /** While holding the BedJet, listen for another phone asking for it. */
    private fun watchForRequests() {
        val request = handoffUuid ?: return
        if (state != LinkState.READY) return
        startScan(ScanFilter.Builder().setServiceUuid(ParcelUuid(request)).build(), forRequests = true)
    }

    private fun startScan(filter: ScanFilter, forRequests: Boolean) {
        stopScan()
        val scanner = adapter?.bluetoothLeScanner ?: return
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post {
                    if (scanning !== this) return@post
                    if (forRequests) {
                        // The only thing scanned for while connected is another phone asking for this BedJet.
                        if (state == LinkState.READY) handOver()
                    } else if (gatt == null) {
                        connect(result.device)
                    }
                }
            }
        }
        scanning = callback
        val mode = if (forRequests) ScanSettings.SCAN_MODE_BALANCED else ScanSettings.SCAN_MODE_LOW_LATENCY
        scanner.startScan(listOf(filter), ScanSettings.Builder().setScanMode(mode).build(), callback)
    }

    private fun stopScan() {
        val callback = scanning ?: return
        scanning = null
        if (hasPermissions() && adapter?.isEnabled == true) adapter.bluetoothLeScanner?.stopScan(callback)
    }

    private fun handOver(attempt: Int = 0) {
        val gatt = gatt ?: return
        if (state != LinkState.READY) return
        if (!canYield() || current != null || operations.isNotEmpty()) {
            // Finish what is in flight first. If that takes too long, keep the BedJet and listen again.
            if (attempt >= 15) return watchForRequests()
            stopScan()
            main.postDelayed({ handOver(attempt + 1) }, 300)
            return
        }
        stopScan()
        yieldedUntil = SystemClock.elapsedRealtime() + COURTESY_MS
        state = LinkState.YIELDED
        gatt.disconnect()
        main.postDelayed({ connectIfPossible() }, COURTESY_MS)
    }

    // Operations

    private fun enqueue(operation: Operation) {
        operations.addLast(operation)
        runNext()
    }

    private fun runNext() {
        if (current != null) return
        val gatt = gatt
        val next = operations.removeFirstOrNull() ?: return
        if (gatt == null) return next.finish(null, BluetoothGatt.GATT_FAILURE)
        current = next
        if (!next.begin(gatt)) {
            current = null
            next.finish(null, BluetoothGatt.GATT_FAILURE)
            runNext()
        }
    }

    /** Called from the Bluetooth callbacks when the operation in flight completes. */
    private fun complete(value: ByteArray?, status: Int) {
        val operation = current ?: return
        current = null
        operation.finish(value, status)
        runNext()
    }

    private suspend fun write(data: ByteArray) {
        val characteristic = command
        if (state != LinkState.READY || characteristic == null) throw BedJetError.NotConnected
        val done = CompletableDeferred<Int>()
        enqueue(Operation(begin = { it.write(characteristic, data) }, finish = { _, status -> done.complete(status) }))
        val status = withTimeoutOrNull(OPERATION_TIMEOUT_MS) { done.await() } ?: run { abandon(); throw BedJetError.Timeout }
        if (status != BluetoothGatt.GATT_SUCCESS) throw BedJetError.NotConnected
    }

    private suspend fun read(): ByteArray {
        val characteristic = reply
        if (state != LinkState.READY || characteristic == null) throw BedJetError.NotConnected
        val done = CompletableDeferred<ByteArray?>()
        enqueue(Operation(begin = { it.readCharacteristic(characteristic) }, finish = { value, _ -> done.complete(value) }))
        val value = withTimeoutOrNull(OPERATION_TIMEOUT_MS) { done.await() } ?: run { abandon(); throw BedJetError.Timeout }
        return value ?: throw BedJetError.BadResponse
    }

    /** An operation the unit never answered stops blocking the ones behind it. */
    private fun abandon() {
        current = null
        runNext()
    }

    private fun BluetoothGatt.write(characteristic: BluetoothGattCharacteristic, data: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= 33) {
            writeCharacteristic(characteristic, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = data
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            writeCharacteristic(characteristic)
        }

    private fun BluetoothGatt.subscribe(characteristic: BluetoothGattCharacteristic): Boolean {
        setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CLIENT_CONFIG) ?: return false
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= 33) {
            writeDescriptor(descriptor, enable) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = enable
            @Suppress("DEPRECATION")
            writeDescriptor(descriptor)
        }
    }

    /**
     * Notifications carry the live readings. When the link's packet size is too small for the whole
     * status, the unit flags the notification as partial and serves the remainder (program progress,
     * LED and beep settings) to a read of the same characteristic.
     */
    private fun receiveStatus(chunk: ByteArray) {
        if (!Codec.isStatusStart(chunk)) {
            val head = lastHead ?: return
            Codec.parseStatus(head + chunk)?.extra?.let { lastExtra = it }
            return
        }
        var status = Codec.parseStatus(chunk) ?: return
        if (status.extra != null) {
            lastExtra = status.extra
        } else {
            status = status.copy(extra = lastExtra)
            lastHead = chunk
            val characteristic = statusCharacteristic
            if (characteristic != null && SystemClock.elapsedRealtime() - lastRemainderRead > 2000) {
                lastRemainderRead = SystemClock.elapsedRealtime()
                enqueue(Operation(begin = { it.readCharacteristic(characteristic) }, finish = { value, _ ->
                    if (value != null) receiveStatus(value)
                }))
            }
        }
        onStatus?.invoke(status)
    }

    private fun seconds(since: Long): Double = (SystemClock.elapsedRealtime() - since) / 1000.0

    private fun discovered(gatt: BluetoothGatt) {
        val service = gatt.getService(SERVICE)
        if (service == null) {
            gatt.disconnect()
            return
        }
        servicesAfter = askedAt?.let { seconds(it) } ?: 0.0
        command = service.getCharacteristic(COMMAND)
        reply = service.getCharacteristic(REPLY)
        statusCharacteristic = service.getCharacteristic(STATUS)
        if (command == null || reply == null) {
            gatt.disconnect()
            return
        }
        statusCharacteristic?.let { status -> enqueue(Operation(begin = { it.subscribe(status) }, finish = { _, _ -> })) }
        service.getCharacteristic(NAME)?.let { name ->
            enqueue(Operation(begin = { it.readCharacteristic(name) }, finish = { value, _ ->
                // The unit's own name identifies it to the other phone during a hand-over.
                if (value != null && value.isNotEmpty()) {
                    prefs.edit().putString(NAME_KEY, Codec.parseText(value)).apply()
                    watchForRequests()
                }
            }))
        }
        // Only connections somebody asked for are timed, not quiet reconnects after a hand-over.
        lastConnection = askedAt?.let { asked ->
            linkUpAfter?.let { ConnectionTiming(radioOnAfter, it, servicesAfter, seconds(asked), knownUnit = !foundByScan) }
        }
        askedAt = null
        linkUpAfter = null
        directFailed = false
        state = LinkState.READY
        watchForRequests()
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (gatt !== this@BleLink.gatt) return@post
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    prefs.edit().putString(REMEMBERED_KEY, gatt.device.address).apply()
                    linkUpAfter = askedAt?.let { seconds(it) }
                    // A larger packet fits the whole status in one notification; the unit copes either way.
                    if (!gatt.requestMtu(64)) gatt.discoverServices()
                } else {
                    if (state != LinkState.READY && state != LinkState.YIELDED && !foundByScan) directFailed = true
                    gatt.close()
                    dropConnection(reconnect = wantsConnection)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post { if (gatt === this@BleLink.gatt) gatt.discoverServices() }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post { if (gatt === this@BleLink.gatt) discovered(gatt) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post { if (gatt === this@BleLink.gatt) complete(null, status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post { if (gatt === this@BleLink.gatt) complete(null, status) }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            val copy = value.copyOf()
            main.post { if (gatt === this@BleLink.gatt) complete(if (status == BluetoothGatt.GATT_SUCCESS) copy else null, status) }
        }

        @Deprecated("Used before Android 13")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            onCharacteristicRead(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid != STATUS) return
            val copy = value.copyOf()
            main.post { if (gatt === this@BleLink.gatt) receiveStatus(copy) }
        }

        @Deprecated("Used before Android 13")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value: ByteArray? = characteristic.value
            if (value != null) onCharacteristicChanged(gatt, characteristic, value)
        }
    }
}
