/// The product's display name, defined once.
///
/// Every user-visible occurrence reads it from here — the title bar, the
/// `MaterialApp` title, the Windows volume-mixer process name and the Settings
/// page — so the name is never repeated as a string literal.
const String appName = 'Sonore';

/// The affiliation line Settings > About carries under the version. The app is
/// an unofficial client and says so on the page that states what it is.
const String appDisclaimer =
    'Unofficial client. Not affiliated with YouTube or Google.';
