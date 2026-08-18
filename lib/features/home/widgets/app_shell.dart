import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 1 tab nằm trong IndexedStack của AppShell (không có nút quay lại).
class ShellTab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Nhận [appBarLeading] (nút mở menu 3 gạch) để truyền vào AppBar của màn
  /// khi chạy trên màn hình hẹp; desktop truyền `null`.
  final Widget Function(Widget? appBarLeading) builder;

  const ShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });
}

/// 1 mục mở màn hình phụ. Trên màn hình rộng (desktop) hiển thị ngay trong
/// vùng nội dung cạnh sidebar (giống tab); trên màn hình hẹp (điện thoại)
/// mở bằng Navigator.push (vẫn có nút quay lại).
class ShellPushItem {
  final String label;
  final IconData icon;
  final WidgetBuilder builder;

  const ShellPushItem({
    required this.label,
    required this.icon,
    required this.builder,
  });
}

/// Khung chính responsive:
/// - Màn hình rộng (desktop): menu trái luôn hiển thị dạng sidebar.
/// - Màn hình hẹp (điện thoại): menu thu gọn thành nút 3 gạch trên AppBar,
///   bấm vào mở Drawer để chọn mục.
class AppShell extends StatefulWidget {
  final String title;
  final List<ShellTab> tabs;
  final List<ShellPushItem> pushItems;

  /// Bấm vào tiêu đề trên sidebar để làm mới toàn bộ app (rebuild cây, tải
  /// lại dữ liệu). Truyền `null` nếu không muốn bấm.
  final VoidCallback? onTitleTap;

  const AppShell({
    super.key,
    required this.title,
    required this.tabs,
    required this.pushItems,
    this.onTitleTap,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Navigator nội bộ vùng nội dung (desktop): các màn chi tiết mở bằng
  /// Navigator.push sẽ hiển thị NGAY trong vùng nội dung cạnh sidebar,
  /// không phủ full màn hình cửa sổ.
  final _contentNavKey = GlobalKey<NavigatorState>();
  static const double _minSidebarWidth = 64;
  static const double _maxSidebarWidth = 360;
  double _sidebarWidth = 240;

  void _openPushItem(int i) {
    _closeDrawerIfOpen();
    if (Platform.isAndroid) {
      Navigator.push(context, _SlideFadePageRoute(builder: widget.pushItems[i].builder));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: widget.pushItems[i].builder));
    }
  }

  void _selectTab(int i) {
    setState(() => _index = i);
    // Trở về màn chính của vùng nội dung khi đổi tab (desktop).
    _contentNavKey.currentState?.popUntil((r) => r.isFirst);
    _closeDrawerIfOpen();
  }

  /// Đóng drawer nếu đang mở (chỉ áp dụng trên màn hình hẹp; desktop không
  /// gắn Scaffold với [_scaffoldKey] nên `currentState` trả null và bỏ qua).
  void _closeDrawerIfOpen() {
    final state = _scaffoldKey.currentState;
    if (state != null && state.isDrawerOpen) {
      state.closeDrawer();
    }
  }

  Widget _hamburger() => IconButton(
        icon: const Icon(Icons.menu),
        tooltip: 'Menu',
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
      );

  Widget _contentPane() {
    return IndexedStack(
      index: _index,
      children: [
        for (final t in widget.tabs) t.builder(null),
        for (final p in widget.pushItems) p.builder(context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 700;
    final showLabels = _sidebarWidth >= 120;

    final menu = _MenuList(
      title: widget.title,
      tabs: widget.tabs,
      pushItems: widget.pushItems,
      selectedIndex: _index,
      pushInline: isWide,
      showLabels: showLabels,
      onSelectTab: _selectTab,
      onSelectPush: _openPushItem,
      onTitleTap: widget.onTitleTap,
    );

    if (isWide) {
      return Scaffold(
        body: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: _sidebarWidth, child: menu),
              _SidebarResizeHandle(
                onDelta: (delta) => setState(() {
                  _sidebarWidth = (_sidebarWidth + delta).clamp(_minSidebarWidth, _maxSidebarWidth);
                }),
              ),
              Expanded(
                // Phím ESC = quay lại trên desktop: pop màn hình con trong vùng
                // nội dung nếu đang mở (dialog/panel phía trên có xử lý ESC riêng
                // ở lớp gần hơn nên chiếm quyền ưu tiên).
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () => _contentNavKey.currentState?.maybePop(),
                  },
                  child: Navigator(
                    key: _contentNavKey,
                    pages: [MaterialPage(child: _contentPane())],
                    onPopPage: (route, result) => route.didPop(result),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      // Mở menu chỉ chiếm ~2/3 màn hình (thay vì gần hết màn hình như mặc định
      // của Drawer) cho gọn mắt, nhất là trên Android.
      drawer: Drawer(
        width: MediaQuery.sizeOf(context).width * 2 / 3,
        child: menu,
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _index,
          children: [for (final t in widget.tabs) t.builder(_hamburger())],
        ),
      ),
    );
  }
}

/// Tay cầm kéo thay đổi độ rộng sidebar trên desktop.
class _SidebarResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDelta;
  const _SidebarResizeHandle({required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDelta(details.delta.dx),
        child: const SizedBox(
          width: 8,
          child: Center(
            child: VerticalDivider(width: 1, thickness: 1),
          ),
        ),
      ),
    );
  }
}

class _MenuList extends StatelessWidget {
  final String title;
  final List<ShellTab> tabs;
  final List<ShellPushItem> pushItems;
  final int selectedIndex;
  final bool pushInline;
  final bool showLabels;
  final ValueChanged<int> onSelectTab;
  final ValueChanged<int> onSelectPush;
  final VoidCallback? onTitleTap;

  const _MenuList({
    required this.title,
    required this.tabs,
    required this.pushItems,
    required this.selectedIndex,
    required this.pushInline,
    required this.showLabels,
    required this.onSelectTab,
    required this.onSelectPush,
    this.onTitleTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Row(
                mainAxisAlignment: showLabels ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  Icon(Icons.phone_android, color: cs.primary),
                  if (showLabels) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: onTitleTap,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title.isEmpty ? 'Cửa hàng sửa chữa' : title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: cs.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (onTitleTap != null) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: 'Nhấn để làm mới dữ liệu',
                                  child: Icon(Icons.refresh, size: 14, color: cs.primary),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _MenuTile(
                      icon: tabs[i].icon,
                      selectedIcon: tabs[i].selectedIcon,
                      label: tabs[i].label,
                      selected: i == selectedIndex,
                      showLabels: showLabels,
                      onTap: () => onSelectTab(i),
                    ),
                  if (pushItems.isNotEmpty) const Divider(height: 20),
                  if (pushInline)
                    for (var i = 0; i < pushItems.length; i++)
                      _MenuTile(
                        icon: pushItems[i].icon,
                        selectedIcon: pushItems[i].icon,
                        label: pushItems[i].label,
                        selected: tabs.length + i == selectedIndex,
                        showLabels: showLabels,
                        onTap: () => onSelectTab(tabs.length + i),
                      )
                  else
                    for (var i = 0; i < pushItems.length; i++)
                      _MenuTile(
                        icon: pushItems[i].icon,
                        selectedIcon: pushItems[i].icon,
                        label: pushItems[i].label,
                        selected: false,
                        showLabels: showLabels,
                        trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
                        onTap: () => onSelectPush(i),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool showLabels;
  final Widget? trailing;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.showLabels,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tile = Padding(
      padding: EdgeInsets.symmetric(horizontal: showLabels ? 12 : 8, vertical: 11),
      child: Material(
        color: selected ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              mainAxisAlignment: showLabels ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 21,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
                if (showLabels) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (showLabels) return tile;
    return Tooltip(message: label, waitDuration: const Duration(milliseconds: 300), child: tile);
  }
}

/// Hiệu ứng mở màn nhẹ nhàng (slide + fade) cho các màn phụ trên Android.
class _SlideFadePageRoute extends PageRouteBuilder {
  final WidgetBuilder builder;

  _SlideFadePageRoute({required this.builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.05, 0.04),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 200),
        );
}
