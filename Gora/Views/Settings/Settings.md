# Settings

The Settings tab is a `NavigationStack` that holds an inset grouped `List`. The system draws the
navigation bar, back button, toggles and alerts, so no view in this folder draws glass.

## Files

| File | Holds |
|---|---|
| `SettingsView.swift` | The list: profile, Commute, Arrival Vibration, Permissions, Data & Privacy, Support, About, Sign Out |
| `SettingsRowIcon.swift` | `SettingsRowIcon` (iOS Settings style: a continuous rounded square filled with the light-mode value of an app color, with a faint lighter top and a white filled SF Symbol; it looks the same in both modes), `SettingsRowLabel`, `.settingsIcon` label style |
| `SettingsAvatar.swift` | Haze circle with the initials of a name |
| `SettingsProfileView.swift` | Profile page: name edit, email, Delete Account |
| `SettingsChoicePage.swift` | `SettingsChoice` protocol, `RoutePriority`, `FareDiscount`, the checkmark list page |
| `SettingsSavedPlacesView.swift` | Saved places list with swipe to delete |
| `SettingsDocument.swift`, `SettingsDocumentView.swift` | Privacy Policy and Terms text, and the page that shows it |
| `SettingsInfoPages.swift` | Download My Data, Report a Route Problem and Acknowledgements pages |
| `SettingsPermissions.swift` | Location and notification access as text |
| `SettingsKey.swift` | Storage keys of the settings |

## Row behavior

| Row | State |
|---|---|
| Saved Places | Works. Reads and deletes through `SavedPlacesStore`. |
| Route Preferences | Stored only. The routing engine does not read it. |
| Fare Discount | Stored only. Fare estimates do not use it. |
| Live Activities | Works. `beginLiveActivity` skips the start when the toggle is off. |
| Near Destination, One Stop Before Exit | Work. Keys `vibrateNearDestination` and `vibrateStopBeforeExit`, default on. `ArrivalAlerts` reads them when an alert fires. Turning one on asks for notification access when it is not decided yet. |
| Location, Notifications | Work. Values refresh when the app becomes active. Tap opens iOS Settings. |
| Save Trip History | Stored only. |
| Share Usage Data | Works. Calls `Analytics.setAnalyticsCollectionEnabled`. `AppDelegate` applies the stored value at launch. |
| Download My Data, Report a Route Problem | Placeholder pages. |
| Help Center, Contact Support | Open a URL with `openURL`. |
| Profile name | Saves with `UserSession.updateDisplayName` (`PATCH /api/v1/me`). |
| Delete Account | `UserSession.deleteAccount` (`DELETE /api/v1/auth/account`), then clears the session. |
