# Settings

The Settings tab is a `NavigationStack` that holds an inset grouped `List`. The system draws the
navigation bar, back button, toggles and alerts, so no view in this folder draws glass.

## Files

| File | Holds |
|---|---|
| `SettingsView.swift` | The list: profile, Commute, Arrival Vibration, Permissions, Data & Privacy, Support, About, Sign Out |
| `SettingsRowIcon.swift` | `SettingsRowIcon` (an outline SF Symbol in `Color.onyx`, near-black in light mode and white in dark mode, with no background; it sets no font, so it takes the row's text font and matches the title size; a fixed 28 pt column, scaled with Dynamic Type, keeps the titles aligned; rows pass outline names, saved places pass `SavedPlaceIcon.outlineSystemImage`, and Live Activities keeps `platter.filled.bottom.iphone`, which has no outline version), `SettingsRowLabel`, `.settingsIcon` label style |
| `SettingsAvatar.swift` | Haze circle with the initials of a name |
| `SettingsProfileView.swift` | Profile page: name edit, email, Delete Account |
| `SettingsChoicePage.swift` | `SettingsChoice` protocol, `RoutePriority`, `FareDiscount`, the checkmark list page |
| `SettingsPaymentsView.swift` | Payment Methods page: one toggle row per payment method of the graph, and its view model |
| `SettingsSavedPlacesView.swift` | Saved places list with swipe to delete |
| `SettingsDocument.swift`, `SettingsDocumentView.swift` | Terms text, and the page that shows it. The Privacy Policy row opens `SettingsWebPageView`, which shows the published web page |
| `SettingsInfoPages.swift` | Download My Data, Report a Route Problem and Acknowledgements pages |
| `SettingsPermissions.swift` | Location and notification access as text |
| `SettingsKey.swift` | Storage keys of the settings |

## Row behavior

| Row | State |
|---|---|
| Saved Places | Works. Reads and deletes through `SavedPlacesStore`. |
| Route Preferences | Stored only. The routing engine does not read it. |
| Fare Discount | Stored only. Fare estimates do not use it. |
| Payment Methods | Works. Key `excludedPayments` holds a `[String]` of the payment IDs that are off, so a new method starts on. `SettingsKey.excludedPaymentIDs` reads it. The page cannot turn off the last method that is on. A change applies to the next route search. The row shows "All", or "on of total" such as "3 of 6". |
| Live Activities | Works. `beginLiveActivity` skips the start when the toggle is off. |
| Near Destination, One Stop Before Exit | Work. Keys `vibrateNearDestination` and `vibrateStopBeforeExit`, default on. `ArrivalAlerts` reads them when an alert fires. Turning one on asks for notification access when it is not decided yet. |
| 24-Hour Time | Works. Key `use24HourTime`, default off (12-hour with AM/PM). `RouteCardSummary` takes it as `uses24HourTime` and formats arrival times as `HH:mm` or `h:mm a`. Views read it with `@AppStorage`, so times update at once. The Live Activity follows the phone's own 12/24-hour setting instead. |
| Location, Notifications | Work. Values refresh when the app becomes active. Tap opens iOS Settings. |
| Save Trip History | Stored only. |
| Share Usage Data | Works. Calls `Analytics.setAnalyticsCollectionEnabled`. `AppDelegate` applies the stored value at launch. |
| Download My Data, Report a Route Problem | Placeholder pages. |
| Help Center, Contact Support | Open a URL with `openURL`. |
| Profile name | Saves with `UserSession.updateDisplayName` (`PATCH /api/v1/me`). |
| Delete Account | `UserSession.deleteAccount` (`DELETE /api/v1/auth/account`), then clears the session. |
