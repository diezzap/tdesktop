/*
This file is part of Telegram Desktop,
the official desktop application for the Telegram messaging service.

For license and copyright information please follow this link:
https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL
*/
#include "platform/mac/specific_mac.h"

#include "lang/lang_keys.h"
#include "mainwidget.h"
#include "history/history_widget.h"
#include "core/crash_reports.h"
#include "core/sandbox.h"
#include "storage/localstorage.h"
#include "mainwindow.h"
#include "history/history_location_manager.h"
#include "platform/mac/mac_utilities.h"

#include <cstdlib>
#include <execinfo.h>
#include <sys/xattr.h>

#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CFURL.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/ev_keymap.h>
#include <SPMediaKeyTap.h>
#include <mach-o/dyld.h>
#include <AVFoundation/AVFoundation.h>

namespace {

QStringList _initLogs;

class _PsEventFilter : public QAbstractNativeEventFilter {
public:
	_PsEventFilter() {
	}

	bool nativeEventFilter(const QByteArray &eventType, void *message, long *result) {
		return Core::Sandbox::Instance().customEnterFromEventLoop([&] {
			auto wnd = App::wnd();
			if (!wnd) return false;

			return wnd->psFilterNativeEvent(message);
		});
	}
};

_PsEventFilter *_psEventFilter = nullptr;

};

namespace {

QRect _monitorRect;
crl::time _monitorLastGot = 0;

} // namespace

QRect psDesktopRect() {
	auto tnow = crl::now();
	if (tnow > _monitorLastGot + 1000 || tnow < _monitorLastGot) {
		_monitorLastGot = tnow;
		_monitorRect = QApplication::desktop()->availableGeometry(App::wnd());
	}
	return _monitorRect;
}

void psShowOverAll(QWidget *w, bool canFocus) {
	objc_showOverAll(w->winId(), canFocus);
}

void psBringToBack(QWidget *w) {
	objc_bringToBack(w->winId());
}

QAbstractNativeEventFilter *psNativeEventFilter() {
	delete _psEventFilter;
	_psEventFilter = new _PsEventFilter();
	return _psEventFilter;
}

void psWriteDump() {
#ifndef TDESKTOP_DISABLE_CRASH_REPORTS
	double v = objc_appkitVersion();
	CrashReports::dump() << "OS-Version: " << v;
#endif // TDESKTOP_DISABLE_CRASH_REPORTS
}

void psDeleteDir(const QString &dir) {
	objc_deleteDir(dir);
}

QStringList psInitLogs() {
	return _initLogs;
}

void psClearInitLogs() {
	_initLogs = QStringList();
}

void psActivateProcess(uint64 pid) {
	if (!pid) {
		objc_activateProgram(App::wnd() ? App::wnd()->winId() : 0);
	}
}

QString psAppDataPath() {
	return objc_appDataPath();
}

void psDoCleanup() {
	try {
		psAutoStart(false, true);
		psSendToMenu(false, true);
	} catch (...) {
	}
}

int psCleanup() {
	psDoCleanup();
	return 0;
}

void psDoFixPrevious() {
}

int psFixPrevious() {
	psDoFixPrevious();
	return 0;
}

namespace Platform {

void start() {
	objc_start();
}

void finish() {
	delete _psEventFilter;
	_psEventFilter = nullptr;

	objc_finish();
}

void StartTranslucentPaint(QPainter &p, QPaintEvent *e) {
#ifdef OS_MAC_OLD
	p.setCompositionMode(QPainter::CompositionMode_Source);
	p.fillRect(e->rect(), Qt::transparent);
	p.setCompositionMode(QPainter::CompositionMode_SourceOver);
#endif // OS_MAC_OLD
}

QString CurrentExecutablePath(int argc, char *argv[]) {
	return NS2QString([[NSBundle mainBundle] bundlePath]);
}

void RemoveQuarantine(const QString &path) {
	const auto kQuarantineAttribute = "com.apple.quarantine";

	DEBUG_LOG(("Removing quarantine attribute: %1").arg(path));
	const auto local = QFile::encodeName(path);
	removexattr(local.data(), kQuarantineAttribute, 0);
}

void RegisterCustomScheme() {
#ifndef TDESKTOP_DISABLE_REGISTER_CUSTOM_SCHEME
	OSStatus result = LSSetDefaultHandlerForURLScheme(CFSTR("tg"), (CFStringRef)[[NSBundle mainBundle] bundleIdentifier]);
	DEBUG_LOG(("App Info: set default handler for 'tg' scheme result: %1").arg(result));
#endif // !TDESKTOP_DISABLE_REGISTER_CUSTOM_SCHEME
}

// I do check for availability, just not in the exact way clang is content with
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
PermissionStatus GetPermissionStatus(PermissionType type) {
#ifndef OS_MAC_OLD
	switch (type) {
		case PermissionType::Microphone:
			if([AVCaptureDevice respondsToSelector: @selector(authorizationStatusForMediaType:)]) { // Available starting with 10.14
				switch([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
					case AVAuthorizationStatusNotDetermined:
						return PermissionStatus::CanRequest;
					case AVAuthorizationStatusAuthorized:
						return PermissionStatus::Granted;
					case AVAuthorizationStatusDenied:
					case AVAuthorizationStatusRestricted:
						return PermissionStatus::Denied;
				}
			}
			break;
	}
#endif // OS_MAC_OLD
	return PermissionStatus::Granted;
}

void RequestPermission(PermissionType type, Fn<void(PermissionStatus)> resultCallback) {
#ifndef OS_MAC_OLD
	switch (type) {
		case PermissionType::Microphone:
			if ([AVCaptureDevice respondsToSelector: @selector(requestAccessForMediaType:completionHandler:)]) { // Available starting with 10.14
				[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
					crl::on_main([=] {
						resultCallback(granted ? PermissionStatus::Granted : PermissionStatus::Denied);
					});
				}];
			}
			break;
	}
#endif // OS_MAC_OLD
	resultCallback(PermissionStatus::Granted);
}
#pragma clang diagnostic pop // -Wunguarded-availability

void OpenSystemSettingsForPermission(PermissionType type) {
#ifndef OS_MAC_OLD
	switch (type) {
		case PermissionType::Microphone:
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
			break;
	}
#endif // OS_MAC_OLD
}

bool OpenSystemSettings(SystemSettingsType type) {
	switch (type) {
	case SystemSettingsType::Audio:
		[[NSWorkspace sharedWorkspace] openFile:@"/System/Library/PreferencePanes/Sound.prefPane"];
		break;
	}
	return true;
}

// Taken from https://github.com/trueinteractions/tint/issues/53.
std::optional<crl::time> LastUserInputTime() {
	CFMutableDictionaryRef properties = 0;
	CFTypeRef obj;
	mach_port_t masterPort;
	io_iterator_t iter;
	io_registry_entry_t curObj;

	IOMasterPort(MACH_PORT_NULL, &masterPort);

	/* Get IOHIDSystem */
	IOServiceGetMatchingServices(masterPort, IOServiceMatching("IOHIDSystem"), &iter);
	if (iter == 0) {
		return std::nullopt;
	} else {
		curObj = IOIteratorNext(iter);
	}
	if (IORegistryEntryCreateCFProperties(curObj, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties != NULL) {
		obj = CFDictionaryGetValue(properties, CFSTR("HIDIdleTime"));
		CFRetain(obj);
	} else {
		return std::nullopt;
	}

	uint64 err = ~0L, idleTime = err;
	if (obj) {
		CFTypeID type = CFGetTypeID(obj);

		if (type == CFDataGetTypeID()) {
			CFDataGetBytes((CFDataRef) obj, CFRangeMake(0, sizeof(idleTime)), (UInt8*)&idleTime);
		} else if (type == CFNumberGetTypeID()) {
			CFNumberGetValue((CFNumberRef)obj, kCFNumberSInt64Type, &idleTime);
		} else {
			// error
		}

		CFRelease(obj);

		if (idleTime != err) {
			idleTime /= 1000000; // return as ms
		}
	} else {
		// error
	}

	CFRelease((CFTypeRef)properties);
	IOObjectRelease(curObj);
	IOObjectRelease(iter);
	if (idleTime == err) {
		return std::nullopt;
	}
	return (crl::now() - static_cast<crl::time>(idleTime));
}

} // namespace Platform

void psNewVersion() {
	Platform::RegisterCustomScheme();
}

void psAutoStart(bool start, bool silent) {
}

void psSendToMenu(bool send, bool silent) {
}

void psUpdateOverlayed(QWidget *widget) {
}

void psDownloadPathEnableAccess() {
	objc_downloadPathEnableAccess(Global::DownloadPathBookmark());
}

QByteArray psDownloadPathBookmark(const QString &path) {
	return objc_downloadPathBookmark(path);
}

QByteArray psPathBookmark(const QString &path) {
	return objc_pathBookmark(path);
}

bool psLaunchMaps(const LocationCoords &coords) {
	return QDesktopServices::openUrl(qsl("https://maps.apple.com/?q=Point&z=16&ll=%1,%2").arg(coords.latAsString()).arg(coords.lonAsString()));
}

QString strNotificationAboutThemeChange() {
	const uint32 letters[] = { 0x75E86256, 0xD03E11B1, 0x4D92201D, 0xA2144987, 0x99D5B34F, 0x037589C3, 0x38ED2A7C, 0xD2371ABC, 0xDC98BB02, 0x27964E1B, 0x01748AED, 0xE06679F8, 0x761C9580, 0x4F2595BF, 0x6B5FCBF4, 0xE4D9C24E, 0xBA2F6AB5, 0xE6E3FA71, 0xF2CFC255, 0x56A50C19, 0x43AE1239, 0x77CA4254, 0x7D189A89, 0xEA7663EE, 0x84CEB554, 0xA0ADF236, 0x886512D4, 0x7D3FBDAF, 0x85C4BE4F, 0x12C8255E, 0x9AD8BD41, 0xAC154683, 0xB117598B, 0xDFD9F947, 0x63F06C7B, 0x6340DCD6, 0x3AAE6B3E, 0x26CB125A };
	return Platform::MakeFromLetters(letters);
}

QString strNotificationAboutScreenLocked() {
	const uint32 letters[] = { 0x34B47F28, 0x47E95179, 0x73D05C42, 0xB4E2A933, 0x924F22D1, 0x4265D8EA, 0x9E4D2CC2, 0x02E8157B, 0x35BF7525, 0x75901A41, 0xB0400FCC, 0xE801169D, 0x4E04B589, 0xC1CEF054, 0xAB2A7EB0, 0x5C67C4F6, 0xA4E2B954, 0xB35E12D2, 0xD598B22B, 0x4E3B8AAB, 0xBEA5E439, 0xFDA8AA3C, 0x1632DBA8, 0x88FE8965 };
	return Platform::MakeFromLetters(letters);
}

QString strNotificationAboutScreenUnlocked() {
	const uint32 letters[] = { 0xF897900B, 0x19A04630, 0x144DA6DF, 0x643CA7ED, 0x81DDA343, 0x88C6B149, 0x5F9A3A15, 0x31804E13, 0xDF2202B8, 0x9BD1B500, 0x61B92735, 0x7DDF5D43, 0xB74E06C3, 0x16FF1665, 0x9098F702, 0x4461DAF0, 0xA3134FA5, 0x52B01D3C, 0x6BC35769, 0xA7CC945D, 0x8B5327C0, 0x7630B9A0, 0x4E52E3CE, 0xED7765E3, 0xCEB7862D, 0xA06B34F0 };
	return Platform::MakeFromLetters(letters);
}

QString strStyleOfInterface() {
	const uint32 letters[] = { 0x3BBB7F05, 0xED4C5EC3, 0xC62C15A3, 0x5D10B283, 0x1BB35729, 0x63FB674D, 0xDBE5C174, 0x401EA195, 0x87B0C82A, 0x311BD596, 0x7063ECFA, 0x4AB90C27, 0xDA587DC4, 0x0B6296F8, 0xAA5603FA, 0xE1140A9F, 0x3D12D094, 0x339B5708, 0x712BA5B1 };
	return Platform::MakeFromLetters(letters);
}

QString strTitleWrapClass() {
	const uint32 letters[] = { 0x066C95DD, 0xA289D425, 0x000EF1A5, 0xB53C76AA, 0x5096391D, 0x212BF5B8, 0xE6BCA526, 0x2A5B8EC6, 0xC1457BDB, 0xA1BEE033, 0xA8ADFA11, 0xFF151585, 0x36EC257D, 0x4D96241D, 0xD0341BAA, 0xDE2908BF, 0xFE7978E8, 0x26875E1D, 0x70DA5557, 0x14C02B69, 0x7EFF7E69, 0x008D7217, 0x5EB01138 };
	return Platform::MakeFromLetters(letters);
}

QString strTitleClass() {
	const uint32 letters[] = { 0x1054BBE5, 0xA39FC333, 0x54B51E1E, 0x24895213, 0x50B71830, 0xBF07478C, 0x10BA5503, 0x5C70D3E6, 0x65079D9D, 0xACAAF939, 0x6A56C3CD };
	return Platform::MakeFromLetters(letters);
}
