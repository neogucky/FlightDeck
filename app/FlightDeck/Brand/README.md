# Departure artwork

The DC-3 mark and detailed airframe were created for FlightDeck during its design exploration. The airframe has no static propeller blades: `LaunchView.swift` renders the spinning propellers separately.

`DC3Front.imageset` contains the matching ivory-and-navy frontal DC-3 from the button design exploration. `AirframeActionButton.swift` renders its propellers separately and uses the actual button lettering as the white material for the 1.2-second morph. It uses native drawing and honours Reduce Motion.

`swift app/make_icon.swift` (run from the repository root on macOS) rebuilds the transparent Departure wordmark and the opaque 1024 × 1024 app icon from `DC3Mark.png`. The icon uses the same navy gradient, ivory plane and curved departure trail as the approved logo. Its square artwork is masked by iOS.

The wordmark uses Space Grotesk at weights 500 and 700, with a slight forward slant. The bundled source font comes from [Google Fonts](https://github.com/google/fonts/tree/main/ofl/spacegrotesk), under the included SIL Open Font License. It is used by the asset generator; the app needs only the generated images.
