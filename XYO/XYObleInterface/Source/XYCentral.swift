//
//  XYCentral.swift
//  XYBleSdk
//
//  Created by Darren Sutherland on 9/6/18.
//  Copyright © 2018 XY - The Findables Company. All rights reserved.
//

import Foundation
import CoreBluetooth
import Promises

// A wrapper around CBPeripheral, used also to mark any devices for restore or delete if the app is killed in the background
public struct XYPeripheral: Hashable, Equatable {
    public let
    peripheral: CBPeripheral,
    advertisementData: [String: Any]?,
    rssi: NSNumber?

    let markedForDisconnect: Bool

    public init(_ peripheral: CBPeripheral, advertisementData: [String: Any]? = nil, rssi: NSNumber? = nil, markedForDisconnect: Bool = false) {
        self.peripheral = peripheral
        self.advertisementData = advertisementData
        self.rssi = rssi
        self.markedForDisconnect = markedForDisconnect
    }

    public static func == (lhs: XYPeripheral, rhs: XYPeripheral) -> Bool {
        return lhs.peripheral == rhs.peripheral
    }

    public var hashValue: Int {
        return self.peripheral.hashValue
    }
}

// MARK: Convert peripheral into beacon definition from ad data, used on Mac OS
internal extension XYPeripheral {

    var beaconDefinitionFromAdData: XYIBeaconDefinition? {
        guard
            let manufacturerData = self.advertisementData?[CBAdvertisementDataManufacturerDataKey] as? Data,
            
            manufacturerData.count == 25
            else { return nil }

        var companyIdentifier: UInt8 = 0
        manufacturerData.copyBytes(to: &companyIdentifier, from: 0..<2)
        guard companyIdentifier == 0x4C else { return nil }
        
        var dataType: UInt8 = 0
        manufacturerData.copyBytes(to: &dataType, from: 2..<3)
        guard dataType == 0x02 else { return nil }
        
        var dataLength: UInt8 = 0
        manufacturerData.copyBytes(to: &dataLength, from: 3..<4)
        guard dataLength == 0x15 else { return nil }
        
        var uuid = [UInt8](repeating: 0, count: 16)
        manufacturerData.copyBytes(to: &uuid, from: 4..<20)
        guard let foundUuid = UUID(uuidString: CBUUID(data: Data(bytes: uuid)).uuidString) else { return nil }
        
        var major = [UInt8](repeating: 0, count: 2)
        manufacturerData.copyBytes(to: &major, from: 20..<22)
        let rawMajor = Data(bytes: major)
        let foundMajor = UInt16(bigEndian: rawMajor.withUnsafeBytes { $0.pointee })
        
        var minor = [UInt8](repeating: 0, count: 2)
        manufacturerData.copyBytes(to: &minor, from: 22..<24)
        let rawMinor = Data(bytes: minor)
        let foundMinor = UInt16(bigEndian: rawMinor.withUnsafeBytes { $0.pointee })
        
        var measuredPower: UInt8 = 0
        manufacturerData.copyBytes(to: &measuredPower, from: 24..<25)

        return XYIBeaconDefinition(uuid: foundUuid, major: foundMajor, minor: foundMinor)
    }

}

public extension CBManagerState {

    public var toString: String {
        switch self {
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        case .resetting: return "Resetting"
        case .unauthorized: return "Unauthorized"
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported"
        }
    }
}

public protocol XYCentralDelegate: class {
    func located(peripheral: XYPeripheral)
    func connected(peripheral: XYPeripheral)
    func timeout()
    func couldNotConnect(peripheral: XYPeripheral)
    func disconnected(periperhal: XYPeripheral)
    func stateChanged(newState: CBManagerState)
}

// Singleton wrapper around CBCentral.
public class XYCentral: NSObject {

    fileprivate var delegates = [String: XYCentralDelegate?]()
    
    public static let instance = XYCentral()

    fileprivate var cbManager: CBCentralManager?

    fileprivate var restoredPeripherals = Set<XYPeripheral>()

    fileprivate var stopOnNoDelegates: Bool = false

    // All BLE operations should be done on this queue
    internal static let centralQueue = DispatchQueue(label:"com.xyfindables.sdk.XYCentralWorkQueue")

    private override init() {
        super.init()
    }

    public var state: CBManagerState {
        return self.cbManager?.state ?? .unknown
    }

    public func enable() {
        guard cbManager == nil || self.state != .poweredOn else { return }

        XYCentral.centralQueue.sync {
            self.cbManager = CBCentralManager(
                delegate: self,
                queue: XYCentral.centralQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.xyfindables.sdk.XYLocate"])
            self.restoredPeripherals.removeAll()
        }
    }

    public func reset() {
        XYCentral.centralQueue.sync {
            self.cbManager?.delegate = nil
            self.cbManager = CBCentralManager(
                delegate: self,
                queue: XYCentral.centralQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.xyfindables.sdk.XYLocate"])
            self.restoredPeripherals.removeAll()
        }
    }

    // Connect to an already discovered peripheral
    public func connect(to device: XYBluetoothDevice, options: [String: Any]? = nil) {
        guard let peripheral = device.peripheral else { return }
        cbManager?.connect(peripheral, options: options)
    }

    // Disconnect from a peripheral
    public func disconnect(from device: XYBluetoothDevice) {
        guard let peripheral = device.peripheral else { return }
        cbManager?.cancelPeripheralConnection(peripheral)
    }

    // Ask for devices with the requested/all services until requested to stop()
    public func scan(for services: [XYServiceCharacteristic]? = nil, stopOnNoDelegates: Bool = false) {
        guard state == .poweredOn else { return }

        guard self.cbManager?.isScanning == false else { return }

        self.stopOnNoDelegates = stopOnNoDelegates
        print("START: Scanning for devices")
        self.cbManager?.scanForPeripherals(
            withServices: services?.map {
                return $0.serviceUuid
            },
            options:[CBCentralManagerScanOptionAllowDuplicatesKey: false, CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // Cancel a scan request from scan() above
    public func stopScan() {
        if stopOnNoDelegates && delegates.count > 0  { return }
        print("STOP: Scanning for devices")
        self.cbManager?.stopScan()
        self.stopOnNoDelegates = false
    }

    public func setDelegate(_ delegate: XYCentralDelegate, key: String) {
        self.delegates[key] = delegate
    }

    public func removeDelegate(for key: String) {
        self.delegates.removeValue(forKey: key)
    }
}

extension XYCentral: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.delegates.forEach {
            $1?.stateChanged(newState: central.state)
        }

        guard central.state == .poweredOn else { return }

        // Disconnected any previously connected peripherals
        self.restoredPeripherals.filter { $0.markedForDisconnect }.forEach {
            self.cbManager?.cancelPeripheralConnection($0.peripheral)
        }
    }

    // Central delegate method called when scanForPeripherals() locates a device. The peripheral will be cached if it is not already and
    // the associated located() delegate method is called
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let wrappedPeripheral = XYPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
        self.delegates.forEach { $1?.located(peripheral: wrappedPeripheral) }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.delegates.forEach { $1?.connected(peripheral: XYPeripheral(peripheral)) }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.delegates.forEach { $1?.couldNotConnect(peripheral: XYPeripheral(peripheral)) }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }

        // Mark any peripherals still connected from the application being closed to be deleted
        peripherals.forEach { peripheral in
            self.restoredPeripherals.insert(XYPeripheral(peripheral, markedForDisconnect: true))
        }
    }

    // If the periperhal disconnects, we will reset the RSSI and report
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let device = XYBluetoothDeviceFactory.build(from: peripheral) as? XYFinderDevice {
            print(" ******* OH NO: Disconnect for \(device.id.shortId) - error: \(error?.localizedDescription ?? "<none>")")

            XYFinderDeviceEventManager.report(events: [.disconnected(device: device)])
            guard device.markedForDeletion == false else { return }

            // TODO: Make sure you yank the peripheral! (Maybe...)

            device.resetRssi()
            self.delegates.forEach { $1?.disconnected(periperhal: XYPeripheral(peripheral)) }

            // Report exited if in background mode
            if XYSmartScan.instance.mode == .background {
                device.startMonitorTimer()
            }
        }
    }
}
