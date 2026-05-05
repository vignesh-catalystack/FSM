# Production Deployment Guide

Use this when moving the FSM app away from ngrok/XAMPP and onto a live HTTPS server.

## 1. Prepare The Live API Server

1. Point a domain or subdomain to your hosting/server.
2. Enable HTTPS with a valid SSL certificate.
3. Upload the PHP backend to a stable path such as:

```text
public_html/fsm_api
```

The app expects endpoints like:

```text
https://your-domain.com/fsm_api/auth/login.php
https://your-domain.com/fsm_api/jobs/get_my_jobs.php
```

4. Import the production database.
5. Update the backend database host, username, password, and database name.
6. Test one API endpoint in the browser or Postman. It must return JSON, not an HTML error page.

## 2. Build The App With HTTPS API URL

Replace the domain below with your real live API URL:

```bash
flutter clean
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://your-domain.com/fsm_api
```

For Play Store upload:

```bash
flutter build appbundle --release --dart-define=API_BASE_URL=https://your-domain.com/fsm_api
```

Release builds will fail at runtime if `API_BASE_URL` is missing or does not use HTTPS.

## 3. Android Release Signing

Before publishing, change `applicationId` in `android/app/build.gradle.kts` from `com.example.fsm` to your real package name, for example `com.yourcompany.fsm`. Do this before the first Play Store release because changing it later creates a different app.

Create a release keystore:

```bash
keytool -genkey -v -keystore android/app/fsm-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias fsm
```

Create `android/key.properties`:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=fsm
storeFile=app/fsm-release.jks
```

Do not commit `android/key.properties` or the `.jks` file. They are already ignored by `.gitignore`.

## 4. Upload To Server Or Store

APK output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

App Bundle output:

```text
build/app/outputs/bundle/release/app-release.aab
```

Install the APK on a real phone and test:

1. Login.
2. Forgot/reset password.
3. Job list.
4. Accept/finish job.
5. Live tracking.
6. Notifications.

## 5. Common Server Requirements

- PHP API must allow mobile requests.
- All endpoints should send JSON headers.
- Server timezone should be configured.
- Database credentials must be production credentials.
- File permissions should allow PHP to read API files but should not expose secrets.
- HTTPS certificate must be valid on Android devices, not self-signed.

## 6. Quick Smoke Test URLs

Check these after upload:

```text
https://your-domain.com/fsm_api/auth/login.php
https://your-domain.com/fsm_api/jobs/get_my_jobs.php
```

If the response is an HTML hosting page, 404 page, or PHP warning page, fix the server path/API before building the app.
