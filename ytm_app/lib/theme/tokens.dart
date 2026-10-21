import 'package:flutter/material.dart';

/// The single source of truth for every color, size, radius, duration and
/// motion value in the app.
///
/// The spec bans color, font-size, radius and duration literals outside
/// `lib/theme/`, and a grep for hex colors, `Icons.`, `BackdropFilter` and
/// numeric font sizes outside `lib/theme/` and `GlassSurface` must return
/// nothing. Screens and widgets read the values below; they never invent them.
///
/// Full-glass direction: the chrome is monochrome — white at varying opacity
/// for fills, borders, text and icons — and the only color the app *owns* is
/// its dark base. Every other color is lifted from the current artwork as the
/// ambient backdrop, so `accent` is gone and active states are white +
/// raised-tint pills instead of a hue.
class Tokens {
  Tokens._();

  // --------------------------------------------------------------- Colors ---

  /// The dark base of the ambient backdrop, near-black with a cold cast. The
  /// art-derived blobs sit on top of it and every screen's chrome is drawn
  /// above the layer; with no artwork (idle) it stays as the neutral gradient
  /// defined by [backdropNeutralTop]/[backdropNeutralBottom].
  static const Color bg = Color(0xFF08080C);

  /// Opaque/placeholding fills: art placeholders, avatars.
  static const Color surface = Color(0xFF141417);

  /// Pressed rows, active pills, disabled fills.
  static const Color surfaceRaised = Color(0xFF1C1C21);

  /// Glass fills, one per tier: white at varying opacity over the artwork.
  /// Thin (rows, quiet cards, inputs) — white 6%.
  static const Color glassThin = Color(0x0FFFFFFF);

  /// Regular (navigation pill, tab bar, hero, cards) — white 9%.
  static const Color glassRegular = Color(0x17FFFFFF);

  /// Thick (transport pill, Now Playing bar, sheets, dialogs, menus) — 14%.
  static const Color glassThick = Color(0x24FFFFFF);

  /// Reduce-transparency / dropped-frames fallback. The fallback is a *solid
  /// tinted* surface (a solid gradient derived from the ambient palette, dimmed
  /// to the dark base), never raw artwork color — layout and contrast must not
  /// change when the fallback engages, only the fill solidifies. These two are
  /// the neutral end of that ramp, used when no palette exists yet.
  static const Color glassFallback = Color(0xFF242427);
  static const Color glassFallbackThin = Color(0xFF212125);

  /// Hairlines on glass (white 10%).
  static const Color border = Color(0x1AFFFFFF);

  /// Focus and hover on glass (white 16%).
  static const Color borderStrong = Color(0x29FFFFFF);

  /// Titles, active labels.
  static const Color text = Color(0xFFFFFFFF);

  /// Subtitles, metadata (passes 4.5:1 on the dark base). #A0A0A8.
  static const Color textSecondary = Color(0xFFA0A0A8);

  /// Durations, hints, large text only. #686870.
  static const Color textMuted = Color(0xFF686870);

  /// Overlays behind modal content (black 90%).
  static const Color scrim = Color(0xE6000000);

  /// Scrim behind on-demand panels (black 30%): the page dims, it does not
  /// disappear — the panel is context, not a modal takeover.
  static const Color panelScrim = Color(0x4D000000);

  /// Specular edge of a glass surface: the 1px border is a gradient from
  /// white 30% at the top-left corner down to white 5% at the bottom-right —
  /// a lit edge rather than a hairline. The top inner highlight carries the
  /// same story with a broad soft band.
  static const Color edgeStrong = Color(0x4DFFFFFF);
  static const Color edgeFaint = Color(0x0DFFFFFF);
  static const Color highlightTop = Color(0x1FFFFFFF);

  /// The 120° floating-surface streak start (white 16%) and full transparency.
  static const Color specular = Color(0x29FFFFFF);
  static const Color transparent = Color(0x00000000);

  /// Shadow under floating chrome (black 45%).
  static const Color shadow = Color(0x73000000);

  /// Black 45% overlay over the ambient backdrop, for legibility.
  static const Color ambientOverlay = Color(0x73000000);

  /// Neutral idle backdrop: a narrow monochrome ramp with no hue.
  static const Color backdropNeutralTop = Color(0xFF121218);
  static const Color backdropNeutralBottom = Color(0xFF08080C);

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

  /// The playing-track variant. There is no accent anymore, so the playing
  /// row reads through weight and brightness rather than hue.
  static TextStyle get rowTitleActive => rowTitle.copyWith(
        fontWeight: FontWeight.w700,
        color: text,
      );

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
  // padding between them. Squircle corners are reserved for the largest radii.

  static const double rSmall = 8;
  static const double rCard = 14;

  /// Glass surfaces live in the 20–28 range: menus and small sheets at 20,
  /// dialogs and large panels at 24.
  static const double rGlassSmall = 20;
  static const double rLarge = 24;

  /// Context-menu rows. The spec's row metrics ("44 px rows") are unchanged;
  /// the container radius joins the glass scale.
  static const double menuRowHeight = 44;

  /// Rounded rectangle (rSmall and pill-ish shapes).
  static OutlinedBorder rounded(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  /// Squircle corners for the largest radii.
  static OutlinedBorder squircle(double radius) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

  /// Picks the corner family a radius token carries: the big shapes are
  /// squircles, everything else a plain rounded rectangle.
  static OutlinedBorder shapeFor(double radius) =>
      (radius == rCard || radius == rGlassSmall || radius == rLarge)
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

  /// Ink-well radii for the floating glass chrome: the tab pill and the
  /// bottom-bar pill are full-height pills, so the sweep radius is half
  /// their height. Radius values live here only.
  static final BorderRadius tabBarPillRadius = BorderRadius.all(
    Radius.circular(tabBarHeight / 2),
  );

  static final BorderRadius navPillRadius = BorderRadius.all(
    Radius.circular(navBarHeight / 2),
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

  // ------------------------------------------------------------- Layout ------
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
  /// it. Only a pill is drawn in that strip; the rest is the backdrop.
  static const double tabBarHeight = 56;
  static const double tabBarMaxWidth = 760;
  static const double shellTopInset = 72;

  /// The widest a form control grows: a slider or text field spanning a 1920
  /// window would make every input an unusable mouse expedition.
  static const double formControlMaxWidth = 480;

  /// The widest any page's content may grow. Everything inside scrolls under
  /// floating chrome; on a 1920 window the rails and rows would otherwise run
  /// edge to edge and every line of text becomes nearly 1900 px long.
  static const double contentMaxWidth = 1240;

  /// The width under which the Popular rail leaves Home: it is a third column
  /// on wide windows, and pushing it below the rails would bury it.
  static const double popularRailVisibleWidth = 1280;

  /// Now Playing queue panel on desktop.
  static const double queuePanelWidth = 320;

  /// Tallest an on-demand bottom sheet grows, so a full queue doesn't leave
  /// the artwork unrecognisable on a small phone.
  static const double sheetMaxHeight = 640;

  /// Bottom sheet: a fling downward faster than this (logical px/s) dismisses
  /// it. Slow drags snap back instead — dismissal needs intent.
  static const double sheetFlingVelocity = 600;

  /// Now Playing artwork bounds.
  static const double artworkMaxPhone = 320;
  static const double artworkMaxDesktop = 460;

  /// Widest the transport block (seek row + pill) grows on a wide screen.
  static const double transportMaxWidth = 460;

  /// Pressing previous restarts the track while it is past this point.
  static const Duration previousRestartThreshold = Duration(seconds: 3);

  // -------------------------------------------------------------- Ambient ---
  //
  // One app-wide ambient backdrop. 2-3 colors lifted from the current artwork
  // are painted as large soft radial blobs over [Tokens.bg] and drift very
  // slowly; the layer cross-fades to the next track's palette. On idle the
  // layer is the neutral monochrome ramp. A faint grain keeps the gradients
  // from banding, and a fixed dark overlay keeps text above 4.5:1.

  static const int ambientColorCount = 3;

  /// Blob softness: the fraction of its alignment lane each blob occupies, so
  /// the light reads as atmosphere, not as three circles.
  static const double ambientBlobExtent = 0.9;

  /// Peak alpha of the strongest blob. Over the veil below it, this keeps
  /// white chrome text at 4.5:1 or better against the worst-bright artwork.
  static const double ambientBlobOpacity = 0.42;

  /// Drift span in alignment units per nudge (±span/2); tiny on purpose.
  static const double ambientDriftSpan = 0.14;

  /// The legibility veil ramps between these two alphas depending on the mean
  /// brightness of the palette — the adaptive part of the contrast guarantee.
  static const double ambientVeilMinAlpha = 0.42;
  static const double ambientVeilMaxAlpha = 0.62;

  /// Grain texture: specks at alpha 0..23, tiled at [grainOpacity].
  static const int grainMaxAlpha = 24;

  /// Rec.709 luma of one color (0..1), used to weight the legibility veil.
  static double lumaOf(Color color) {
    final double r = color.r, g = color.g, b = color.b;
    return _luma[0] * r + _luma[1] * g + _luma[2] * b;
  }

  /// How strongly the Home hero's art-derived tint reads inside the banner.
  /// The hero is the one card the approved layout lets artwork color into;
  /// everywhere else color comes only from the ambient layer behind glass.
  static const double heroTintOpacity = 0.45;

  /// Adaptive text scrim for the hero: when the tint's luma passes this gate,
  /// a black wash ramps in underneath the hero type, reaching full strength
  /// at luma 1.0 — the guarantee behind "title holds 4.5:1 whatever the art".
  static const double heroScrimLumaGate = 0.45;
  static const double heroScrimMaxAlpha = 0.55;

  /// Blob geometry: three anchors, the first near the top-left, so the palette
  /// reads immediately behind floating chrome and settles toward the base.
  static const List<Alignment> ambientPlacements = <Alignment>[
    Alignment(-0.55, -0.65),
    Alignment(0.75, -0.05),
    Alignment(-0.15, 0.85),
  ];

  /// Drift: each blob nudges to a new anchor offset once per period and moves
  /// there slowly over the move window. Slow on purpose — it should read as
  /// light, not as motion.
  static const Duration ambientDriftPeriod = Duration(seconds: 24);
  static const Duration ambientDriftMove = Duration(seconds: 10);

  /// Track change: the whole layer cross-fades, so a palette swap is a breath,
  /// not a jump.
  static const Duration dAmbientCrossfade = Duration(milliseconds: 600);

  /// Grain overlay: a seeded random alpha texture, tiled, at this opacity —
  /// just enough to stop the gradients from banding, invisible up close.
  static const double grainOpacity = 0.05;
  static const int grainSize = 128;

  // --------------------------------------------------------------- Seek bar ---

  static const double seekBarThickness = 4;
  static const double seekBarThicknessActive = 8;

  /// The hairline variant used inside the floating Now Playing bar: a
  /// whisper-thin track by default that thickens under the pointer.
  static const double seekBarThicknessCompact = 2;
  static const double seekBarThicknessCompactActive = 3;

  /// The compact scrubber's hit area — smaller than a full touch target,
  /// because the bar's transport buttons carry the touch interactions, and a
  /// taller zone would swallow taps meant for the track title beneath it.
  static const double seekHitHeightCompact = 16;

  /// A small round thumb that grows out of the track on hover and while
  /// dragging, on both the full and the compact scrubber.
  static const double seekThumbSize = 12;

  // ---------------------------------------------------------------- Glass ----
  //
  // One [GlassSurface] widget owns the recipe; nothing else may call
  // BackdropFilter. Three tiers share it: blur + saturation of what is behind,
  // the gradient edge, the top highlight and (for floating surfaces) a shadow.

  static const double glassBlurThin = 18;
  static const double glassBlurRegular = 30;
  static const double glassBlurThick = 42;

  /// Backdrop saturation boost, shared by all tiers (spec: ~1.4–1.8).
  static const double glassSaturation = 1.6;
  static const double borderWidth = 1;
  static const double glassShadowOffset = 12;
  static const double glassShadowBlur = 32;

  /// Specular streak: a 120-degree linear gradient from white 16% to
  /// transparent at 60%, clipped to the pill.
  static const double glassSpecularStop = 0.6;
  static const Alignment specularBegin = Alignment(-0.866, -0.5);
  static const Alignment specularEnd = Alignment(0.866, 0.5);

  /// Top inner highlight: a vertical gradient from [Tokens.highlightTop] to
  /// transparent, gone by this fraction of the surface height.
  static const double glassHighlightStop = 0.4;

  /// Edge gradient: lit at the top-left, fading to almost nothing bottom-right.
  static const Alignment edgeBegin = Alignment(-0.7, -0.7);
  static const Alignment edgeEnd = Alignment(0.7, 0.7);

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
  static const Duration dHover = Duration(milliseconds: 200);

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

  /// Play/pause artwork scale.
  static const double artworkPlayingScale = 1.0;
  static const double artworkPausedScale = 0.86;

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
