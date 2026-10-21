import 'package:flutter/material.dart';

/// The single source of truth for every color, size, radius, duration and
/// motion value in the app.
///
/// The spec bans color, font-size, radius and duration literals outside
/// `lib/theme/`, and a grep for hex colors, `Icons.`, `BackdropFilter` and
/// numeric font sizes outside `lib/theme/` and `GlassSurface` must return
/// nothing. Screens and widgets read the values below; they never invent them.
///
/// Batch 1 note: the dark palette values below were re-verified against the
/// exported Figma spec (design.pdf, "Resonance for Windows"). Three color
/// deltas were extracted from the vector fills — secondary text #A0A0A8,
/// muted text #686870, and the glass tint at white 8% — replacing values
/// taken from the earlier mock draft. The opaque glass fallback is #242427,
/// confirmed by the materials board ("Solid raised #242427, no backdrop
/// blur").
class Tokens {
  Tokens._();

  // --------------------------------------------------------------- Colors ---

  /// Page background, always true black.
  static const Color bg = Color(0xFF000000);

  /// Opaque fallbacks: art placeholders, avatars.
  static const Color surface = Color(0xFF141417);

  /// Pressed rows, disabled fills.
  static const Color surfaceRaised = Color(0xFF1C1C21);

  /// Top bar, bottom nav, Follow glass (white 8%). Extracted from the Figma
  /// fills; the previous 6% came from the older mock draft.
  static const Color glass = Color(0x14FFFFFF);

  /// Anchored Now Playing bar, transport pill, sheets (white 10%).
  static const Color glassStrong = Color(0x1AFFFFFF);

  /// Reduce-transparency / dropped-frames fallback. The materials board pins
  /// this to solid #242427 with no backdrop blur — layout and contrast must
  /// not change when the fallback engages.
  static const Color glassFallback = Color(0xFF242427);

  /// Hairlines on glass (white 10%).
  static const Color border = Color(0x1AFFFFFF);

  /// Focus and hover on glass (white 16%).
  static const Color borderStrong = Color(0x29FFFFFF);

  /// Active state only: playing track, progress fill, liked heart, active nav.
  static const Color accent = Color(0xFFFA2D48);

  /// Titles, active labels.
  static const Color text = Color(0xFFFFFFFF);

  /// Subtitles, metadata (passes 4.5:1 on the true-black background).
  /// #A0A0A8 was extracted from the most common non-white text fill in the
  /// Figma export.
  static const Color textSecondary = Color(0xFFA0A0A8);

  /// Durations, hints, large text only. #686870 from the Figma fills; the
  /// earlier #7A7A7A came from the mock draft.
  static const Color textMuted = Color(0xFF686870);

  /// Overlays behind modal content (black 90%).
  static const Color scrim = Color(0xE6000000);

  /// Specular streak start (white 16%) and full transparency.
  static const Color specular = Color(0x29FFFFFF);
  static const Color transparent = Color(0x00000000);

  /// Shadow under floating chrome (black 40%).
  static const Color shadow = Color(0x66000000);

  /// Black 45% overlay over the ambient artwork blur, for legibility.
  static const Color ambientOverlay = Color(0x73000000);

  // ----------------------------------------------------------- Typography ---
  //
  // Spec type roles. Phone sizes are the defaults; desktop overrides exist for
  // the two roles the spec differentiates (page title, row title).
  // Weights are restricted to 400 / 500 / 600 / 700. Sentence case, no
  // all-caps.

  static const String fontFamily = 'Inter';

  /// Text scales with the system setting up to 1.3x.
  static const double textScaleCap = 1.3;
  static const double textScaleMin = 1.0;

  /// The on-by-default text scale: the standard scale, not the ceiling.
  ///
  /// 1.3 is what the app *allows*, not what it chooses — starting a fresh
  /// install at the maximum scale made every screen look cramped before the
  /// user had asked for it. A stored choice still wins ([AppSettings] persists
  /// it), so upgrading keeps whatever the user picked.
  static const double textScaleDefault = 1.0;

  static const TextStyle pageTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: text,
  );

  static const TextStyle pageTitleDesktop = TextStyle(
    fontFamily: fontFamily,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: text,
  );

  /// Now Playing track title (spec: 24/700 on compact, larger on desktop).
  static const TextStyle nowPlayingTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: text,
  );

  static const TextStyle sectionHeader = TextStyle(
    fontFamily: fontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    color: text,
  );

  static const TextStyle rowTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    color: text,
  );

  static const TextStyle rowTitleDesktop = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    color: text,
  );

  /// The playing-track variant. Accent is the only active-state color.
  static final TextStyle rowTitleActive = rowTitle.copyWith(color: accent);

  static const TextStyle subtitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    color: textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    color: textMuted,
  );

  // ---------------------------------------------------------------- Shape ---
  //
  // Nested rounded shapes are concentric: inner radius = outer radius minus the
  // padding between them. rCard and rLarge use squircle corners.

  static const double rSmall = 8;
  static const double rCard = 14;
  static const double rLarge = 24;

  /// The spec's middle radius step, used by context menus: "44 px rows,
  /// 12 px radius" (section 3.J).
  ///
  /// Note: the spec's radius scale is 8 / 12 / 20 / pill, while `rCard` and
  /// `rLarge` are 14 and 24 from the Phase 2 pass. That gap predates this work
  /// and is recorded as P11 in `proof/phase4.txt` rather than changed here,
  /// because Phase 4 must preserve the existing design system.
  static const double rMenuItem = 12;

  /// Context-menu row height (spec section 3.J).
  static const double menuRowHeight = 44;

  /// Rounded rectangle (rSmall and pill-ish shapes).
  static OutlinedBorder rounded(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  /// Squircle corners for rCard and rLarge.
  static OutlinedBorder squircle(double radius) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

  /// Picks the corner family the spec assigns to a radius token.
  static OutlinedBorder shapeFor(double radius) =>
      (radius == rCard || radius == rLarge)
      ? squircle(radius)
      : rounded(radius);

  /// Full-radius pill used by buttons, nav pill, transport controls.
  static const OutlinedBorder shapePill = StadiumBorder();

  /// The anchored Now Playing bar is part of the layout, not a floating pill:
  /// square corners, flush with the window's sides and bottom edge.
  static const OutlinedBorder shapeAnchoredBar = RoundedRectangleBorder();

  /// The same radius, for widgets that take a `BorderRadius` (ink wells and
  /// clips) rather than an [OutlinedBorder]. Radius values live here only.
  static const BorderRadius rSmallBorder = BorderRadius.all(
    Radius.circular(rSmall),
  );

  // -------------------------------------------------------------- Spacing ---
  //
  // Gaps and padding use these and nothing else.

  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s48 = 48;

  /// Left and right of every page.
  static const double pageMarginPhone = 20;
  static const double pageMarginDesktop = 32;

  // ----------------------------------------------------------------- Icons ---
  //
  // One set (Phosphor), regular weight, 24px. Hit area is 48x48 even when the
  // glyph is smaller.

  static const double iconSize = 24;
  static const double minTouchTarget = 48;

  // ------------------------------------------------------------- Layout -----
  //
  // Shell measurements, defined once here so no screen carries a literal.

  /// Desktop layout kicks in above this width; below it the sidebar becomes
  /// an icon rail and, on phones, the bottom bar.
  static const double breakpointDesktop = 900;

  static const double sidebarWidth = 200;
  static const double sidebarRailWidth = 72;

  /// The persistent Now Playing bar docked to the bottom of the content area.
  /// Its progress line sits inside this height, at the top edge.
  static const double nowPlayingBarHeight = 64;

  static const double listRowHeight = 64;
  static const double artTileSize = 108;
  static const double artThumbSize = 48;

  /// A Home rail card: 108px artwork plus two text lines, measured so the text
  /// still fits at the 1.3x text-scale ceiling rather than overflowing.
  static const double railCardHeight = 172;

  /// Below this width the Home hero stacks its artwork above the title and the
  /// actions instead of sitting them side by side, which is what a 320 px
  /// phone needs for the pills to fit.
  static const double heroStackBelowWidth = 300;

  /// A collection header's artwork (album / playlist / artist page).
  static const double collectionArtSize = 160;
  static const double heroArtDesktop = 176;
  static const double popularRailWidth = 250;

  /// Phone layout: below this width the sidebar is replaced by the bottom bar.
  static const double breakpointPhone = 600;

  /// The app draws its own Windows title bar, so this is its height and the
  /// hit width of each caption button. The Figma frames draw a 36 px bar with
  /// a 46x36 caption hit area.
  static const double titleBarHeight = 36;
  static const double captionButtonWidth = 46;

  /// Glass bottom bar on phones.
  static const double navBarHeight = 64;

  /// The floating glass top tab bar (wide layouts, i.e. at and above
  /// [breakpointPhone]): its own height, the widest it grows before it stops
  /// stretching, and the strip it floats over so content is never hidden behind
  /// it. Only a pill is drawn in that strip; the rest is the page background.
  static const double tabBarHeight = 56;
  static const double tabBarMaxWidth = 760;
  static const double shellTopInset = 72;

  /// Now Playing queue panel on desktop.
  static const double queuePanelWidth = 320;

  /// Now Playing artwork bounds.
  static const double artworkMaxPhone = 320;
  static const double artworkMaxDesktop = 380;

  /// Widest the transport block (seek row + pill) grows on a wide screen.
  static const double transportMaxWidth = 460;

  /// The fraction of the viewport one carousel artwork occupies.
  static const double carouselViewportFraction = 0.68;

  /// Pressing previous restarts the track while it is past this point.
  static const Duration previousRestartThreshold = Duration(seconds: 3);

  // -------------------------------------------------------------- Ambient ---
  //
  // Now Playing only: 2-3 colors lifted from the current artwork as blurred
  // radial gradients, with a black 45% overlay on top for legibility.

  static const double ambientBlur = 90;
  static const double ambientOpacity = 0.55;
  static const int ambientColorCount = 3;

  /// How strongly the Home hero's art-derived tint reads inside the banner.
  ///
  /// The hero is the one card the approved layout lets artwork color into;
  /// everywhere else color comes only from the artwork itself or the accent.
  static const double heroTintOpacity = 0.45;

  // --------------------------------------------------------------- Seek bar ---

  static const double seekBarThickness = 4;
  static const double seekBarThicknessActive = 8;
  static const double progressLineThin = 2;

  // ---------------------------------------------------------------- Glass ----
  //
  // One [GlassSurface] widget owns the recipe; nothing else may call
  // BackdropFilter.

  static const double glassBlur = 30;
  static const double glassSaturation = 1.8;
  static const double borderWidth = 1;
  static const double glassShadowOffset = 8;
  static const double glassShadowBlur = 24;

  /// Specular streak: a 120-degree linear gradient from white 16% to
  /// transparent at 60%, clipped to the pill.
  static const double glassSpecularStop = 0.6;
  static const Alignment specularBegin = Alignment(-0.866, -0.5);
  static const Alignment specularEnd = Alignment(0.866, 0.5);

  /// Limit: three live blurs per screen.
  static const int maxLiveBlurs = 3;

  /// Rec.709 luma weights used to build the saturation matrix.
  static const List<double> _luma = <double>[0.2126, 0.7152, 0.0722];

  /// A 5x4 color matrix that scales saturation, used to compose the glass
  /// filter with the blur.
  static List<double> saturationMatrix(double saturation) {
    final double inv = 1 - saturation;
    final double r = inv * _luma[0];
    final double g = inv * _luma[1];
    final double b = inv * _luma[2];
    return <double>[
      r + saturation, g, b, 0, 0, //
      r, g + saturation, b, 0, 0, //
      r, g, b + saturation, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  // --------------------------------------------------------------- Motion ----

  static const Duration dPress = Duration(milliseconds: 80);
  static const Duration dPageChange = Duration(milliseconds: 200);
  static const Duration dFadeIn = Duration(milliseconds: 200);
  static const Duration dAmbientCrossfade = Duration(milliseconds: 300);

  /// Skeleton shimmer while a screen is loading (1.4 s loop per the states
  /// board; the earlier 1.2 s came from the mock draft).
  static const Duration dShimmer = Duration(milliseconds: 1400);

  /// With Reduce Motion on, movement is replaced by a 150 ms fade.
  static const Duration dReduceMotionFade = Duration(milliseconds: 150);

  /// How long a failure toast stays up. Short on purpose: it reports a write
  /// that did not happen, it is not something the user has to act on.
  static const Duration dSnackbar = Duration(seconds: 3);

  static const Curve curvePress = Curves.easeOut;
  static const Curve curveRelease = Curves.elasticOut;
  static const Curve curvePageChange = Curves.easeOut;

  /// Settle for spring-driven motion (carousel snap, artwork scale). The spec's
  /// default spring is approximated with a curve rather than a physics
  /// simulation, which keeps the animations declarative and interruptible.
  static const Curve curveSpring = Curves.easeOutBack;

  /// Page change: a 200 ms opacity crossfade with NO slide — the motion board
  /// states "Quick 200ms opacity crossfade, never a slide", so this stays 0.
  /// Kept as a token so screens referencing it still compose.
  static const double pageSlide = 0;

  /// Press: scale to 0.97.
  static const double pressScale = 0.97;

  /// Tile hover: scale keeps at 103% per the motion spec ("Tile hover 103%,
  /// deeper shadow"). Used by artwork tiles in Batch 3.
  static const double hoverScale = 1.03;

  /// Hover transition: the spec gives 200-300 ms ease-out for the hover state;
  /// the low end keeps hover responsive without flutter.
  static const Duration dHover = Duration(milliseconds: 200);

  /// Play/pause artwork scale.
  static const double artworkPlayingScale = 1.0;
  static const double artworkPausedScale = 0.86;

  /// Carousel geometry.
  static const double carouselNeighborScale = 0.8;
  static const double carouselNeighborOpacity = 0.35;
  static const double carouselCurrentOpacity = 0.6;
  static const double carouselPerspective = 0.001;
  static const double carouselNeighborRotateY = 0.61; // 35 degrees in radians

  /// Default spring: mass 1, stiffness 320, damping 30.
  static const double springMass = 1;
  static const double springStiffness = 320;
  static const double springDamping = 30;
  static const SpringDescription spring = SpringDescription(
    mass: springMass,
    stiffness: springStiffness,
    damping: springDamping,
  );
}
