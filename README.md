#  H10 Alert app

The app uses Polar Ble SDK to get ECG data from the Polar H10 fitness tracker and alert the user and witnesses about user's heart rate being too low too high or heart rhythm being irregular.

The main UI screen is implemented in `ViewController` class. It gets samples from the device and then uses `HRChecker` class which, in turn, uses `ECGStreamingAnalyser` to get R-R intervals using Pan-Tompkins algorithm. There is also `PolarApiWrapper` a thin wrapper that handles connecting to the tracker.

There is an option to take a photo of the electrodes but for now that just saves the photo to the App folder in the iOS built in Files app. There are plans to make a web application for managing all the H10Alert users, with options to send notifications and receive reports of at home AED use which would contain this photo.

The app also saves all the ECG data received from the tracker for later analysis. The data model is `ECGData`. It stores the actual samples in `ECGDataFile` segments. This is so we don't lose a lot of data should the app get closed by the system.

The rest is recording previews and export lifted straight from the main H10Ecg app.
