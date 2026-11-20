import { AppRegistry, Platform } from 'react-native';
import ReplayIQ from '@replayiq/react-native';
import App from './App';
import { name as appName } from './app.json';

// Local ReplayIQ (./dev.sh): the Android emulator reaches the host at 10.0.2.2.
export const ENDPOINT = Platform.OS === 'android' ? 'http://10.0.2.2:8080' : 'http://localhost:8080';

ReplayIQ.init('verify', ENDPOINT, { recordingMode: 'auto' });

AppRegistry.registerComponent(appName, () => App);
