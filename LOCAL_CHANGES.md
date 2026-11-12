Vendored from print_bluetooth_thermal 1.2.1 (pub.dev), under the original LICENSE.
Dart, Android, Windows, and macOS implementations are unchanged.

iOS fixes:
- Complete connect only after discovering a known writable printer endpoint.
- Bound chunks by the negotiated BLE write limit (up to 150 bytes).
- Wait for acknowledgements for writes with response.
- Observe CoreBluetooth capacity and resume callbacks for writes without response.
- Complete each write Future once after the whole payload has been submitted.
- Separate connection, scan, and write callbacks and add bounded waits.
- Send text through the same write path.

This fork retains CocoaPods integration. Upstream 1.2.2+ switches Apple support
to Swift Package Manager, requiring a separate Flutter/build migration review.

Hardware verification on macOS:
1. Run flutter pub get, then pod install in ios, and rebuild the app.
2. Select the printer and print a settings test.
3. Print a full receipt with logo, local-language images, QR code, footer and cut.
4. Print consecutive receipts and KOTs, including switching printers.
5. Disconnect during printing and confirm failure returns without hanging.

Successful submission does not confirm physical paper output. iOS requires a
compatible BLE printer.
