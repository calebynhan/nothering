import CoreBluetooth
import Foundation
import os

/// The phone's end of the Bluetooth wake (see `DirectLinkWake`): a small Bluetooth service that
/// stays reachable while the app is suspended. iOS wakes the app when the Mac reads or writes it,
/// and brings the app back if it had ended it to free memory. An app the person swiped away stays
/// closed.
///
/// It needs the `bluetooth-peripheral` background mode, and has to be created each time the app
/// launches, also in the background, for iOS to hand the service back to it.
public final class DirectLinkWakeBeacon: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
  /// What iOS remembers the service under while the app isn't running.
  private static let restoreIdentifier = "app.nothering.wake"
  private static let serviceUUID = CBUUID(string: DirectLinkWake.serviceID)
  private static let challengeUUID = CBUUID(string: DirectLinkWake.challengeID)
  private static let answerUUID = CBUUID(string: DirectLinkWake.answerID)

  private let queue = DispatchQueue(label: "app.nothering.wake")
  private let onWake: @Sendable () -> Void
  private let logger = Logger(subsystem: "app.nothering", category: "wake")
  private var challenger: WakeChallenger
  private var manager: CBPeripheralManager?
  /// Whether the service is published. iOS keeps it across a relaunch and drops it when Bluetooth
  /// is turned off.
  private var hasService = false

  /// Whether the person turned Bluetooth off for this app, so no Mac can wake it.
  public static var isDenied: Bool {
    CBManager.authorization == .denied || CBManager.authorization == .restricted
  }

  /// `onWake` is called, on a private queue, when a Mac that knows `code` asks for the proxy.
  public init(code: String, onWake: @escaping @Sendable () -> Void) {
    challenger = WakeChallenger(code: code)
    self.onWake = onWake
    super.init()
    manager = CBPeripheralManager(
      delegate: self,
      queue: queue,
      options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
    )
  }

  /// A new pairing code: Macs that know the old one are no longer let in.
  public func use(code: String) {
    queue.async { [self] in
      challenger = WakeChallenger(code: code)
    }
  }

  /// Advertises the service again if that stopped, e.g. while Bluetooth was off. Called when the
  /// app comes to the front: an app in the background may not be allowed to start it.
  public func refresh() {
    queue.async { [self] in
      guard let manager, manager.state == .poweredOn, hasService, !manager.isAdvertising else { return }
      advertise(on: manager)
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    // What iOS kept published while the app was gone. Adding it again would publish it twice.
    let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
    hasService = services.contains { $0.uuid == Self.serviceUUID }
  }

  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral.state == .poweredOn else {
      // The Mac then finds no iPhone, with nothing to say why. This is where it can be read.
      logger.notice("wake service not usable, Bluetooth state \(peripheral.state.rawValue)")
      if peripheral.state == .poweredOff || peripheral.state == .resetting {
        hasService = false
      }
      return
    }
    guard !hasService else {
      if !peripheral.isAdvertising { advertise(on: peripheral) }
      return
    }
    // No stored values: both are answered when asked, which is also what wakes the app.
    let challenge = CBMutableCharacteristic(type: Self.challengeUUID, properties: .read, value: nil, permissions: .readable)
    let answer = CBMutableCharacteristic(type: Self.answerUUID, properties: .write, value: nil, permissions: .writeable)
    let service = CBMutableService(type: Self.serviceUUID, primary: true)
    service.characteristics = [challenge, answer]
    hasService = true
    // After Bluetooth was only switched off iOS may still hold the service. Nothing to remove when
    // it dropped it, and no second copy when it kept it.
    peripheral.removeAllServices()
    peripheral.add(service)
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error {
      logger.error("wake service: \(error.localizedDescription, privacy: .public)")
      hasService = false
      return
    }
    advertise(on: peripheral)
  }

  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      logger.error("wake advertising: \(error.localizedDescription, privacy: .public)")
    } else {
      logger.info("wake service advertised")
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == Self.challengeUUID else {
      return peripheral.respond(to: request, withResult: .readNotPermitted)
    }
    guard request.offset == 0 else {
      return peripheral.respond(to: request, withResult: .invalidOffset)
    }
    request.value = challenger.issue(to: request.central.identifier)
    peripheral.respond(to: request, withResult: .success)
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let request = requests.first else { return }
    // The Mac's answer is one short write. Anything else isn't from it.
    guard requests.count == 1, request.characteristic.uuid == Self.answerUUID, request.offset == 0,
          let answer = request.value, challenger.accepts(answer, from: request.central.identifier)
    else {
      // Not one of the codes that say "secure this connection first": a Mac would answer those by
      // starting Bluetooth pairing with this iPhone, alert and all.
      return peripheral.respond(to: request, withResult: .writeNotPermitted)
    }
    peripheral.respond(to: request, withResult: .success)
    logger.info("a paired Mac asks for the proxy")
    onWake()
  }

  /// Only the service, no name: in the background iOS drops the name anyway, and the Mac looks for
  /// the service.
  private func advertise(on peripheral: CBPeripheralManager) {
    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
  }
}
