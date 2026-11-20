import CoreBluetooth
import Foundation
import os

/// The Mac's end of the Bluetooth wake (see `DirectLinkWake`): finds the phone's wake service,
/// proves it knows the pairing code, and so has the phone's app start its proxy.
public final class DirectLinkWaker: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  public enum Outcome: Equatable, Sendable {
    /// The phone accepted and is starting its proxy.
    case woke
    /// An iPhone with Nothering answered and turned this Mac down: it has another pairing code.
    /// This Mac's own wasn't found.
    case refused
    /// No iPhone with Nothering answered in time: out of range, Bluetooth off on it, or its app was
    /// swiped away.
    case notFound
    /// Bluetooth can't be used on this Mac until the person changes something.
    case unavailable(String)
  }

  private static let serviceUUID = CBUUID(string: DirectLinkWake.serviceID)
  private static let challengeUUID = CBUUID(string: DirectLinkWake.challengeID)
  private static let answerUUID = CBUUID(string: DirectLinkWake.answerID)
  /// How long a phone that said no isn't asked again: asking wakes its app, for another no. After
  /// about this long an iPhone shows a new Bluetooth address anyway, and counts as a new phone.
  private static let refusalMemory: TimeInterval = 15 * 60

  private let code: String
  private let queue = DispatchQueue(label: "app.nothering.wake")
  private let logger = Logger(subsystem: "app.nothering", category: "wake")
  private var central: CBCentralManager?
  private var completion: (@Sendable (Outcome) -> Void)?
  private var attempt = 0
  private var timeout: TimeInterval = 12
  /// Whether this attempt got as far as looking. Before that macOS may still be asking the person
  /// whether Bluetooth may be used.
  private var isScanning = false
  /// The phones being asked, by identifier. Core Bluetooth doesn't keep them. All at once, so one
  /// that doesn't answer holds up no other.
  private var asking: [UUID: CBPeripheral] = [:]
  /// Phones that led nowhere in this attempt: not Nothering after all, or gone again.
  private var skipped: Set<UUID> = []
  /// Phones that turned this Mac down, and when. Kept between attempts.
  private var refusedAt: [UUID: Date] = [:]
  /// Whether a phone turned this Mac down in this attempt, or would have.
  private var sawRefusal = false

  public init(code: String) {
    self.code = code
  }

  /// Looks for the phone for up to `timeout` seconds and asks it to start its proxy. `completion`
  /// is called once, on a private queue. A call while another runs ends that one first.
  public func wake(timeout: TimeInterval = 12, completion: @escaping @Sendable (Outcome) -> Void) {
    queue.async { [self] in
      endAttempt()
      attempt += 1
      self.completion = completion
      self.timeout = timeout
      let now = Date()
      refusedAt = refusedAt.filter { now.timeIntervalSince($0.value) < Self.refusalMemory }
      if central == nil {
        // Creating it is what makes macOS ask for Bluetooth access, so not before it is needed.
        // Its first state update starts the scan.
        central = CBCentralManager(delegate: self, queue: queue)
      } else {
        scanIfReady()
      }
    }
  }

  /// Gives up without calling the completion.
  public func cancel() {
    queue.async { [self] in
      completion = nil
      attempt += 1
      stop()
    }
  }

  // MARK: Finding the phone (on `queue`)

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    scanIfReady()
  }

  private func scanIfReady() {
    guard completion != nil, !isScanning, let central else { return }
    switch central.state {
    case .poweredOn:
      isScanning = true
      central.scanForPeripherals(withServices: [Self.serviceUUID])
      // The time to find the phone in starts here, not while macOS is still asking the person
      // whether Bluetooth may be used.
      let current = attempt
      queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, attempt == current else { return }
        finish(sawRefusal ? .refused : .notFound)
      }
    case .unauthorized:
      finish(.unavailable("Allow Bluetooth for Nothering, or for the terminal it runs in, in System Settings > Privacy & Security > Bluetooth, so it can wake your iPhone"))
    case .poweredOff:
      finish(.unavailable("Turn Bluetooth on, so Nothering can wake your iPhone"))
    case .unsupported:
      finish(.unavailable("This Mac has no Bluetooth to wake your iPhone with"))
    default:
      // Not known yet. The next state update decides.
      break
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let id = peripheral.identifier
    guard completion != nil, asking[id] == nil, !skipped.contains(id) else { return }
    guard refusedAt[id] == nil else {
      // It said no a moment ago and would again.
      sawRefusal = true
      return
    }
    asking[id] = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.serviceUUID])
  }

  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    skip(peripheral)
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // Before its answer came: it went out of range, or it was let go.
    asking[peripheral.identifier] = nil
  }

  // MARK: Asking it (on `queue`)

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    // In the background an iPhone advertises its services in a form that also matches some
    // iPhones without Nothering. Those end here.
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
      return skip(peripheral)
    }
    peripheral.discoverCharacteristics([Self.challengeUUID, Self.answerUUID], for: service)
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let challenge = service.characteristics?.first(where: { $0.uuid == Self.challengeUUID }) else {
      return skip(peripheral)
    }
    peripheral.readValue(for: challenge)
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, characteristic.uuid == Self.challengeUUID,
          let challenge = characteristic.value, challenge.count == DirectLinkWake.challengeSize,
          let answer = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.answerUUID })
    else {
      return skip(peripheral)
    }
    peripheral.writeValue(DirectLinkWake.answer(code: code, challenge: challenge), for: answer, type: .withResponse)
  }

  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard asking[peripheral.identifier] != nil else { return }
    guard let error else {
      logger.info("the iPhone accepted the wake")
      return finish(.woke)
    }
    if (error as NSError).domain == CBATTErrorDomain {
      // The phone itself said no: it has another pairing code. This Mac's may be among the others.
      logger.notice("wake refused: \(error.localizedDescription, privacy: .public)")
      refusedAt[peripheral.identifier] = Date()
      sawRefusal = true
    }
    skip(peripheral)
  }

  /// Lets go of a phone that led nowhere, for the rest of this attempt.
  private func skip(_ peripheral: CBPeripheral) {
    skipped.insert(peripheral.identifier)
    asking[peripheral.identifier] = nil
    central?.cancelPeripheralConnection(peripheral)
  }

  /// Ends the attempt that is running, if one is, as what it came to.
  private func endAttempt() {
    guard completion != nil else { return }
    if isScanning {
      finish(sawRefusal ? .refused : .notFound)
    } else {
      // It never got to look: Bluetooth hasn't said yet whether it may be used.
      finish(.unavailable("Bluetooth isn't ready yet. If macOS asks whether Nothering, or the terminal it runs in, may use Bluetooth, allow it"))
    }
  }

  private func finish(_ outcome: Outcome) {
    guard let completion else { return }
    self.completion = nil
    stop()
    completion(outcome)
  }

  private func stop() {
    if let central, central.state == .poweredOn {
      if isScanning { central.stopScan() }
      for peripheral in asking.values {
        central.cancelPeripheralConnection(peripheral)
      }
    }
    isScanning = false
    asking = [:]
    skipped = []
    sawRefusal = false
  }
}
