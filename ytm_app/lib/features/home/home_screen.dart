import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../theme/tokens.dart';
import '../../ui/data_states.dart';
import '../../ui/media_rows.dart';

/// The Home destination: real personalized rows from the sidecar.
///
/// Spec: Home's rails come from the service, with no fabricated content, and it
/// supports loading skeletons, a helpful empty state, retry on error and a
/// distinct offline state. Rails the service returns empty are dropped before
/// they reach here, so a rail always has cards.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConnectionGate(
      loading: const ListSkeleton(),
      child: DataStateView<List<HomeRow>>(
        value: ref.watch(homeProvider),
        onRetry: () => ref.invalidate(homeProvider),
        isEmpty: (List<HomeRow> rows) => rows.isEmpty,
        emptyMessage: 'Nothing to show on Home yet.',
        emptyFootnote: 'Listen to a few tracks and your mixes will appear here.',
        loading: const ListSkeleton(),
        data: (List<HomeRow> rows) => _HomeRails(rows: rows),
      ),
    );
  }
}

class _HomeRails extends ConsumerWidget {
  const _HomeRails({required this.rows});

  final List<HomeRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin =
        isDesktop ? Tokens.pageMarginDesktop : Tokens.pageMarginPhone;

    return RefreshIndicator(
      color: Tokens.accent,
      backgroundColor: Tokens.surfaceRaised,
      onRefresh: () async {
        ref.invalidate(connectionProvider);
        ref.invalidate(homeProvider);
        await ref.read(homeProvider.future);
      },
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          margin,
          Tokens.s24,
          margin,
          Tokens.shellBottomInset,
        ),
        itemCount: rows.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Tokens.s16),
              child: Text(
                'Good evening',
                style: isDesktop ? Tokens.pageTitleDesktop : Tokens.pageTitle,
              ),
            );
          }
          return _HomeRail(row: rows[index - 1]);
        },
      ),
    );
  }
}

class _HomeRail extends StatelessWidget {
  const _HomeRail({required this.row});

  final HomeRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(row.title, style: Tokens.sectionHeader),
          const SizedBox(height: Tokens.s12),
          SizedBox(
            height: Tokens.railCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: row.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: Tokens.s16),
              itemBuilder: (BuildContext context, int index) => MediaCard(
                item: row.items[index],
                siblings: row.items,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
