import Flutter
import UIKit
import CoreBluetooth

// Local CocoaPods-compatible fix for receipt-sized writes on modern iOS.
public class SwiftPrintBluetoothThermalPlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var printer: CBPeripheral?
    private var output: CBCharacteristic?
    private var devices: [String] = []
    private var scanResult: FlutterResult?
    private var scanWaiters: [FlutterResult] = []
    private var pendingServices = 0
    private var writableCandidates: [CBCharacteristic] = []
    private var connectResult: FlutterResult?
    private var writeResult: FlutterResult?
    private var pendingData = Data()
    private var offset = 0
    private var awaitingResponse = false
    private var connectTimeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "groons.web.app/print", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SwiftPrintBluetoothThermalPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
        switch call.method {
        case "getPlatformVersion": result("iOS " + UIDevice.current.systemVersion)
        case "getBatteryLevel":
            UIDevice.current.isBatteryMonitoringEnabled = true
            result(Int(UIDevice.current.batteryLevel * 100))
        case "bluetoothenabled", "ispermissionbluetoothgranted": result(central.state == .poweredOn)
        case "pairedbluetooths":
            if scanResult != nil { scanWaiters.append(result); return }
            guard central.state == .poweredOn || central.state == .unknown || central.state == .resetting else { result([String]()); return }
            devices = []
            scanResult = result
            if let peripheral = printer, peripheral.state == .connected { addDevice(peripheral, name: peripheral.name) }
            if central.state == .poweredOn { central.scanForPeripherals(withServices: nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self.central.stopScan()
                let completion = self.scanResult
                self.scanResult = nil
                completion?(self.devices)
                let waiters = self.scanWaiters
                self.scanWaiters = []
                for waiter in waiters { waiter(self.devices) }
            }
        case "connect":
            guard let address = call.arguments as? String, let id = UUID(uuidString: address),
                  central.state == .poweredOn, connectResult == nil, writeResult == nil else {
                result(false); return
            }
            if printer?.identifier == id, printer?.state == .connected, output != nil {
                result(true); return
            }
            if let previous = printer, previous.identifier != id {
                central.cancelPeripheralConnection(previous)
            }
            output = nil
            pendingServices = 0
            writableCandidates = []
            guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
                printer = nil; result(false); return
            }
            printer = peripheral
            peripheral.delegate = self
            connectResult = result
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.connectResult != nil else { return }
                self.finishConnect(false)
                self.central.cancelPeripheralConnection(peripheral)
            }
            connectTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            if peripheral.state == .connected { peripheral.discoverServices(nil) }
            else { central.connect(peripheral) }
        case "connectionstatus": result(printer?.state == .connected && output != nil)
        case "writebytes":
            guard let values = call.arguments as? [Int], values.allSatisfy({ 0...255 ~= $0 }) else {
                result(false); return
            }
            beginWrite(Data(values.map { UInt8($0) }), result: result)
        case "printstring":
            guard let text = call.arguments as? String else { result(false); return }
            let parts = text.components(separatedBy: "///")
            let size = parts.count > 1 ? (Int(parts[0]) ?? 2) : 2
            let commands: [[UInt8]] = [[0x1d,0x21,0], [0x1b,0x4d,1], [0x1b,0x4d,0],
                                      [0x1d,0x21,0x11], [0x1d,0x21,0x22], [0x1d,0x21,0x33]]
            var data = Data(commands[(1...5).contains(size) ? size : 2])
            data.append(Data((parts.count > 1 ? parts.dropFirst().joined(separator: "///") : text).utf8))
            data.append(contentsOf: [0x1b, 0x40])
            beginWrite(data, result: result)
        case "disconnect":
            finishWrite(false)
            finishConnect(false)
            output = nil
            if let peripheral = printer { central.cancelPeripheralConnection(peripheral) }
            printer = nil
            result(true)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func finishConnect(_ success: Bool) {
        connectTimeout?.cancel()
        connectTimeout = nil
        let completion = connectResult
        connectResult = nil
        completion?(success)
    }

    private func beginWrite(_ data: Data, result: @escaping FlutterResult) {
        guard writeResult == nil, printer?.state == .connected, output != nil else { result(false); return }
        writeResult = result
        pendingData = data
        offset = 0
        awaitingResponse = false
        drainWrite()
    }

    private func armWriteTimeout() {
        writeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finishWrite(false) }
        writeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private func finishWrite(_ success: Bool) {
        writeTimeout?.cancel()
        writeTimeout = nil
        let completion = writeResult
        writeResult = nil
        pendingData = Data()
        offset = 0
        awaitingResponse = false
        completion?(success)
    }

    private func drainWrite() {
        guard writeResult != nil, let peripheral = printer, let characteristic = output,
              peripheral.state == .connected else { finishWrite(false); return }
        if awaitingResponse { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        // Respect the negotiated MTU and CoreBluetooth backpressure. A response write
        // advances only after its acknowledgement; an unacknowledged write resumes
        // from peripheralIsReady(toSendWriteWithoutResponse:).
        let chunkSize = min(150, peripheral.maximumWriteValueLength(for: type))
        guard chunkSize > 0 else { finishWrite(false); return }
        while offset < pendingData.count {
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                armWriteTimeout(); return
            }
            let end = min(offset + chunkSize, pendingData.count)
            let chunk = pendingData.subdata(in: offset..<end)
            offset = end
            awaitingResponse = type == .withResponse
            armWriteTimeout()
            peripheral.writeValue(chunk, for: characteristic, type: type)
            if awaitingResponse { return }
        }
        finishWrite(true)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral == printer else { return }
        drainWrite()
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == printer, characteristic == output, writeResult != nil, awaitingResponse else { return }
        if error != nil { finishWrite(false); return }
        awaitingResponse = false
        drainWrite()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        addDevice(peripheral, name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }

    private func addDevice(_ peripheral: CBPeripheral, name: String?) {
        let name = name ?? "Bluetooth device"
        let device = "\(name)#\(peripheral.identifier.uuidString)"
        let suffix = "#\(peripheral.identifier.uuidString)"
        devices.removeAll { $0.hasSuffix(suffix) }
        devices.append(device)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == printer else { return }
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == printer else { return }
        output = nil
        finishConnect(false)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == printer else { return }
        output = nil
        finishConnect(false)
        finishWrite(false)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == printer else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { finishConnect(false); return }
        pendingServices = services.count
        writableCandidates = []
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == printer, connectResult != nil, output == nil else { return }
        pendingServices -= 1
        if error == nil {
            writableCandidates += (service.characteristics ?? []).filter {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
        }
        // Known printer endpoints, including common FFE0/FFE1 and 18F0/2AF1 devices.
        let ids = ["00001101-0000-1000-8000-00805F9B34FB", "49535343-8841-43F4-A8D4-ECBE34729BB3",
                   "A76EB9E2-F3AC-4990-84CF-3A94D2426B2B", "FFE1", "2AF1", "FF02"]
        if let characteristic = writableCandidates.first(where: {
            ids.contains($0.uuid.uuidString) && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse))
        }) {
            output = characteristic
            finishConnect(true)
        } else if pendingServices == 0 {
            // Unlisted models are safe to use automatically only when their
            // services expose a single writable endpoint.
            if writableCandidates.count == 1 {
                output = writableCandidates[0]
                finishConnect(true)
            } else {
                finishConnect(false)
            }
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, scanResult != nil {
            central.scanForPeripherals(withServices: nil)
        }
        if central.state != .poweredOn {
            output = nil
            finishConnect(false)
            finishWrite(false)
        }
    }
}
