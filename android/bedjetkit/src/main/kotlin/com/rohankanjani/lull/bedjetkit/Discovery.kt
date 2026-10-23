package com.rohankanjani.lull.bedjetkit

/** A BedJet advertising nearby, which can be chosen. It only advertises while no phone is connected to it. */
data class NearbyBedJet(
    /** The Bluetooth identifier this phone knows the unit by. It never changes, unlike the name. */
    val id: String,
    val name: String,
    /** Known from what the unit advertises for a BedJet 3; a V2 is only certain once it has connected. */
    val generation: Generation?,
    /** Signal strength in dBm. Closer usually reads stronger, but walls and bodies get in the way. */
    val rssi: Int,
) {
    enum class Signal(val title: String) { STRONG("Strong"), FAIR("Fair"), WEAK("Weak") }

    val signal: Signal get() = if (rssi >= -60) Signal.STRONG else if (rssi >= -75) Signal.FAIR else Signal.WEAK
}

/**
 * Whether a unit found by scanning is the one a link is for. Another BedJet is never taken in its place,
 * even when the right one is away: it could be a partner's. Only a link made without a unit takes any.
 */
fun takes(found: String, boundTo: String?): Boolean = boundTo?.let { it == found } ?: true

/** Lists the BedJets advertising nearby without connecting to any of them, so one can be picked. */
interface BedJetDiscovery {
    val nearby: List<NearbyBedJet>
    /** [LinkState.SEARCHING] while it can look, otherwise why it can't. */
    val state: LinkState
    var onChange: (() -> Unit)?
    fun start()
    fun stop()
}

/** Simulated BedJets nearby, for demo mode and tests. They are all there as soon as it starts. */
class DemoDiscovery(units: List<NearbyBedJet> = SIMULATED) : BedJetDiscovery {
    override var nearby: List<NearbyBedJet> = emptyList()
        private set
    override var state: LinkState = LinkState.SEARCHING
        set(value) { field = value; onChange?.invoke() }
    override var onChange: (() -> Unit)? = null
    /** What a scan finds. Changing it while scanning is like a unit turning on or off. */
    var units: List<NearbyBedJet> = units
        set(value) { field = value; if (isScanning) show() }

    private var isScanning = false

    companion object {
        /** Two share the default name, as real units often do, so the app has to tell them apart. */
        val SIMULATED = listOf(
            NearbyBedJet("D3A0B1E7-0000-4000-8000-00000000DE01", DemoLink.DEFAULT_NAME, Generation.V3, -52),
            NearbyBedJet("5F2C9A41-0000-4000-8000-00000000DE02", DemoLink.DEFAULT_NAME, Generation.V3, -68),
            NearbyBedJet("8B7E44C2-0000-4000-8000-00000000DE03", "BEDJET-GUEST", Generation.V3, -81),
        )
    }

    override fun start() {
        isScanning = true
        show()
    }

    override fun stop() {
        isScanning = false
        nearby = emptyList()
        onChange?.invoke()
    }

    private fun show() {
        nearby = units
        onChange?.invoke()
    }
}
