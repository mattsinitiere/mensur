# Apple API references checked during implementation

Checked October 16, 2026. Apple documentation JSON was also inspected for current declarations.

- RoomPlan overview: https://developer.apple.com/documentation/roomplan
- RoomCaptureViewDelegate: https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate
- Processed callback: https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate/captureview(didpresent:error:)
- Capture session: https://developer.apple.com/documentation/roomplan/roomcapturesession
- Surface and parent/transform/polygon properties: https://developer.apple.com/documentation/roomplan/capturedroom/surface
- Export options and differences between mesh/parametric: https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions
- RoomPlan introduction and limitations for mirrors/glass: https://developer.apple.com/videos/play/wwdc2022/10127/
- Parametric modeling background: https://machinelearning.apple.com/research/roomplan

Apple's WWDC guidance explicitly identifies full-height mirrors and glass as difficult for LiDAR. No software workflow in this project is represented as removing that sensor limitation.
