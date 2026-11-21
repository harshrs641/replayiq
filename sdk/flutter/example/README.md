# replayiq_flutter example

A checkout demo recorded with `replayiq_flutter`: text fields (masked),
a `ReplayIQMask`, a button to rage-tap, a named route, a failing HTTP call,
a thrown error and `print` / `debugPrint` output.

```bash
flutter run --dart-define=RIQ_ENDPOINT=http://localhost:8080 --dart-define=RIQ_KEY=verify
```

Use `http://10.0.2.2:8080` from the Android emulator. The session id is
shown at the top of the screen; open it at
`http://localhost:3000/?session=<id>`.
