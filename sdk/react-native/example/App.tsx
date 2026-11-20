import React, { useEffect, useState } from 'react';
import { FlatList, Pressable, SafeAreaView, StyleSheet, Text, TextInput, View } from 'react-native';
import ReplayIQ, { ReplayIQMask } from '@replayiq/react-native';
import { ENDPOINT } from './index';

type Screen = 'checkout' | 'summary';

const items = Array.from({ length: 30 }, (_, i) => ({ id: String(i + 1), name: `Item ${i + 1}`, price: (i + 1) * 5 }));

function Button({ label, onPress, primary }: { label: string; onPress: () => void; primary?: boolean }) {
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={label} onPress={onPress}
      style={({ pressed }) => [styles.button, primary && styles.primary, pressed && { opacity: 0.7 }]}>
      <Text style={[styles.buttonText, primary && { color: '#fff' }]}>{label}</Text>
    </Pressable>
  );
}

function Checkout({ go }: { go: (s: Screen) => void }) {
  const [status, setStatus] = useState('');
  return (
    <View style={styles.body}>
      <Text style={styles.title}>Checkout</Text>
      <Text style={styles.muted}>Wireless earbuds · $65.00</Text>
      <TextInput style={styles.input} placeholder="Full name" accessibilityLabel="Full name" />
      <TextInput style={styles.input} placeholder="Card number" accessibilityLabel="Card number" keyboardType="number-pad" />
      <ReplayIQMask style={styles.card}>
        <Text style={styles.cardText}>Saved card ···· 4242 · Jane Doe</Text>
      </ReplayIQMask>
      <Button primary label="Pay now" onPress={() => { ReplayIQ.track('pay_tapped', { total: 65 }); setStatus('Payment failed'); }} />
      <Button label="Order summary" onPress={() => go('summary')} />
      <Button label="Load prices (fails)" onPress={async () => {
        const res = await fetch(`${ENDPOINT}/demo/prices`);
        console.warn(`Prices request returned ${res.status}`);
      }} />
      <Button label="Apply coupon (throws)" onPress={() => {
        // Uncaught JS error: reaches the ErrorUtils handler.
        setTimeout(() => { throw new TypeError('Coupon service returned no discount'); }, 0);
      }} />
      <Button label="Log error" onPress={() => console.error(new Error('Inventory sync failed'))} />
      {status ? <Text style={styles.error}>{status}</Text> : null}
    </View>
  );
}

function Summary({ go }: { go: (s: Screen) => void }) {
  return (
    <View style={{ flex: 1 }}>
      <View style={styles.bar}>
        <Pressable accessibilityRole="button" accessibilityLabel="Back" onPress={() => go('checkout')}><Text style={styles.back}>‹ Back</Text></Pressable>
        <Text style={styles.barTitle}>Order summary</Text>
      </View>
      <FlatList data={items} keyExtractor={i => i.id} renderItem={({ item }) => (
        <View style={styles.row}><Text>{item.name}</Text><Text style={styles.muted}>${item.price}.00</Text></View>
      )} />
    </View>
  );
}

export default function App() {
  const [screen, setScreen] = useState<Screen>('checkout');
  // Without React Navigation, report screens directly (with it: trackNavigation(ref)).
  useEffect(() => { ReplayIQ.screen(screen === 'checkout' ? 'Checkout' : 'OrderSummary'); }, [screen]);
  return (
    <SafeAreaView style={styles.root}>
      {screen === 'checkout' ? <Checkout go={setScreen} /> : <Summary go={setScreen} />}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#f9fafb' },
  body: { padding: 20, gap: 12 },
  title: { fontSize: 28, fontWeight: '700', color: '#111827' },
  muted: { color: '#6b7280' },
  input: { borderWidth: 1, borderColor: '#d1d5db', borderRadius: 8, padding: 12, backgroundColor: '#fff' },
  card: { borderRadius: 10, padding: 14, backgroundColor: '#eef2ff' },
  cardText: { color: '#3730a3' },
  button: { borderRadius: 10, padding: 14, alignItems: 'center', borderWidth: 1, borderColor: '#c7d2fe', backgroundColor: '#fff' },
  primary: { backgroundColor: '#4f46e5', borderColor: '#4f46e5' },
  buttonText: { color: '#4338ca', fontWeight: '600' },
  error: { color: '#b91c1c', fontWeight: '600' },
  bar: { flexDirection: 'row', alignItems: 'center', padding: 16, borderBottomWidth: 1, borderColor: '#e5e7eb', gap: 16 },
  back: { color: '#4f46e5', fontSize: 17 },
  barTitle: { fontSize: 18, fontWeight: '600' },
  row: { flexDirection: 'row', justifyContent: 'space-between', padding: 16, borderBottomWidth: 1, borderColor: '#f3f4f6', backgroundColor: '#fff' },
});
