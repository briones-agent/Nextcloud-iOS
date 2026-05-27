import {
  popToNative,
  useSharedState,
  sendMessage,
  addMessageListener,
} from 'expo-brownfield';
import { useEffect, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  View,
  useColorScheme,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';

interface RecentFile {
  id: number;
  name: string;
  path: string;
  ext: string;
  color: string;
  size: string;
  modified: string;
  shared: boolean;
}

const NEXTCLOUD_BLUE = '#0082C9';

export default function FilesQuickLook() {
  const scheme = useColorScheme();
  const cardBg = scheme === 'dark' ? '#1C1C1E' : '#F2F2F7';
  const subtle = scheme === 'dark' ? '#3A3A3C' : '#E5E5EA';
  const muted = scheme === 'dark' ? '#8E8E93' : '#6E6E73';

  const [files] = useSharedState<RecentFile[]>('recentFiles', []);
  const [totalFiles] = useSharedState<number>('totalFiles', 0);
  const [usedGB] = useSharedState<number>('usedGB', 0);
  const [quotaGB] = useSharedState<number>('quotaGB', 0);
  const [pendingUploads] = useSharedState<number>('pendingUploads', 0);
  const [lastSyncedAt] = useSharedState<string>('lastSyncedAt', '');

  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    const sub = addMessageListener((msg) => {
      if (msg.type === 'FILE_OPENED') {
        setToast(`Opening "${msg.name}"…`);
      } else if (msg.type === 'SYNC_FINISHED') {
        setToast(`Sync finished · ${msg.uploaded ?? 0} uploaded`);
      }
      setTimeout(() => setToast(null), 2400);
    });
    return () => sub.remove();
  }, []);

  const time = lastSyncedAt
    ? new Date(lastSyncedAt).toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit',
      })
    : '—';

  const used = usedGB ?? 0;
  const quota = quotaGB ?? 1;
  const pct = Math.min(100, Math.round((used / quota) * 100));

  return (
    <ThemedView style={styles.root}>
      <SafeAreaView style={styles.safe} edges={['top', 'bottom']}>
        <View style={[styles.header, { borderBottomColor: subtle }]}>
          <ThemedText style={styles.headerTitle}>Files Quick Look</ThemedText>
          <Pressable
            onPress={() => popToNative(true)}
            hitSlop={8}
            style={({ pressed }) => [
              styles.closeBtn,
              { backgroundColor: NEXTCLOUD_BLUE, opacity: pressed ? 0.6 : 1 },
            ]}
          >
            <ThemedText style={styles.closeText}>Done</ThemedText>
          </Pressable>
        </View>

        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.hero}>
            <View style={[styles.icon, { backgroundColor: NEXTCLOUD_BLUE }]}>
              <ThemedText style={styles.iconGlyph}>N</ThemedText>
            </View>
            <ThemedText type="title" style={styles.title}>
              Your cloud
            </ThemedText>
            <ThemedText style={[styles.subtitle, { color: muted }]}>
              Rendered by React Native inside Nextcloud iOS — dismiss via{' '}
              <ThemedText style={styles.code}>popToNative()</ThemedText>
            </ThemedText>
          </View>

          <View style={[styles.quotaCard, { backgroundColor: cardBg }]}>
            <View style={styles.quotaHeader}>
              <ThemedText style={styles.quotaTitle}>Storage</ThemedText>
              <ThemedText style={[styles.quotaPercent, { color: muted }]}>
                {used.toFixed(1)} GB / {quota} GB · {pct}%
              </ThemedText>
            </View>
            <View
              style={[styles.quotaTrack, { backgroundColor: subtle }]}
            >
              <View
                style={[
                  styles.quotaFill,
                  { width: `${pct}%`, backgroundColor: NEXTCLOUD_BLUE },
                ]}
              />
            </View>
            <View style={styles.quotaFooter}>
              <ThemedText style={[styles.quotaSubtitle, { color: muted }]}>
                {totalFiles ?? 0} files · last synced {time}
              </ThemedText>
              {(pendingUploads ?? 0) > 0 && (
                <ThemedText style={[styles.quotaSubtitle, { color: NEXTCLOUD_BLUE }]}>
                  {pendingUploads} pending
                </ThemedText>
              )}
            </View>
          </View>

          <Pressable
            onPress={() => sendMessage({ type: 'SYNC_NOW' })}
            style={({ pressed }) => [
              styles.actionRow,
              { backgroundColor: cardBg, opacity: pressed ? 0.7 : 1 },
            ]}
          >
            <View style={{ flex: 1 }}>
              <ThemedText style={styles.actionTitle}>Sync now</ThemedText>
              <ThemedText style={[styles.actionSubtitle, { color: muted }]}>
                Push pending uploads + fetch remote changes
              </ThemedText>
            </View>
            <ThemedText style={[styles.chevron, { color: NEXTCLOUD_BLUE }]}>
              ↻
            </ThemedText>
          </Pressable>

          <ThemedText style={[styles.section, { color: muted }]}>
            Recently modified · tap to open
          </ThemedText>

          <View style={[styles.list, { backgroundColor: cardBg }]}>
            {(files ?? []).map((f, idx) => (
              <Pressable
                key={f.id}
                onPress={() => {
                  sendMessage({ type: 'OPEN_FILE', id: f.id, name: f.name });
                  setTimeout(() => popToNative(true), 400);
                }}
                style={({ pressed }) => [
                  styles.row,
                  idx < (files?.length ?? 0) - 1 && {
                    borderBottomColor: subtle,
                    borderBottomWidth: StyleSheet.hairlineWidth,
                  },
                  pressed && { opacity: 0.6 },
                ]}
              >
                <View style={[styles.fileIcon, { backgroundColor: f.color }]}>
                  <ThemedText style={styles.fileExt}>
                    {f.ext.toUpperCase()}
                  </ThemedText>
                </View>
                <View style={{ flex: 1 }}>
                  <View style={styles.rowHead}>
                    <ThemedText style={styles.rowTitle} numberOfLines={1}>
                      {f.name}
                    </ThemedText>
                    {f.shared && (
                      <ThemedText style={[styles.shared, { color: NEXTCLOUD_BLUE }]}>
                        ↗
                      </ThemedText>
                    )}
                  </View>
                  <ThemedText
                    style={[styles.rowDomain, { color: muted }]}
                    numberOfLines={1}
                  >
                    {f.path} · {f.size} · {f.modified}
                  </ThemedText>
                </View>
              </Pressable>
            ))}
          </View>

          {toast && (
            <View style={[styles.toast, { backgroundColor: NEXTCLOUD_BLUE }]}>
              <ThemedText style={styles.toastText}>{toast}</ThemedText>
            </View>
          )}
        </ScrollView>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  safe: { flex: 1 },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  headerTitle: { flex: 1, fontSize: 17, fontWeight: '600' },
  closeBtn: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 14,
  },
  closeText: { color: '#fff', fontWeight: '600', fontSize: 13 },
  scroll: { padding: Spacing.three, gap: Spacing.three },
  hero: { alignItems: 'center', paddingTop: Spacing.two, gap: 8 },
  icon: {
    width: 64,
    height: 64,
    borderRadius: 32,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconGlyph: { color: '#fff', fontSize: 30, fontWeight: '800' },
  title: { fontSize: 24, fontWeight: '700' },
  subtitle: { fontSize: 13, textAlign: 'center', paddingHorizontal: 12 },
  code: { fontFamily: 'Menlo', fontSize: 12 },
  quotaCard: {
    padding: Spacing.three,
    borderRadius: 12,
    gap: 8,
  },
  quotaHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
  },
  quotaTitle: { fontSize: 15, fontWeight: '600' },
  quotaPercent: { fontSize: 12 },
  quotaTrack: {
    height: 8,
    borderRadius: 4,
    overflow: 'hidden',
  },
  quotaFill: { height: 8, borderRadius: 4 },
  quotaFooter: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
  },
  quotaSubtitle: { fontSize: 12 },
  actionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: Spacing.two,
    borderRadius: 12,
    gap: Spacing.two,
  },
  actionTitle: { fontSize: 15, fontWeight: '600' },
  actionSubtitle: { fontSize: 12, marginTop: 2 },
  chevron: { fontSize: 24, fontWeight: '400' },
  section: {
    fontSize: 12,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    paddingHorizontal: 4,
  },
  list: { borderRadius: 12, overflow: 'hidden' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: Spacing.two,
    gap: Spacing.two,
  },
  fileIcon: {
    width: 40,
    height: 40,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  fileExt: { color: '#fff', fontWeight: '700', fontSize: 11 },
  rowHead: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  rowTitle: { fontSize: 15, fontWeight: '600' },
  shared: { fontSize: 14, fontWeight: '700' },
  rowDomain: { fontSize: 12, marginTop: 2 },
  toast: {
    position: 'absolute',
    bottom: 20,
    left: 20,
    right: 20,
    padding: 12,
    borderRadius: 10,
    alignItems: 'center',
  },
  toastText: { color: '#fff', fontWeight: '600' },
});
