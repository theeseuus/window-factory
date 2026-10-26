// Query signatures/masks follow MIT-licensed Hammerspoon 1.1.1 spaces.
// See THIRD_PARTY_NOTICES.md. Mutations are scoped below.
#import "Bridge.h"
#include <dlfcn.h>
typedef int (*MainFn)(void);
typedef CFArrayRef (*DisplaysFn)(int);
typedef int (*TypeFn)(int,uint64_t);
typedef CFArrayRef (*MembershipFn)(int,int,CFArrayRef);
typedef AXError (*WindowIDFn)(AXUIElementRef,CGWindowID *);
static void *handle;
static MainFn connection;
static DisplaysFn displays;
static TypeFn spaceType;
static MembershipFn membership;
static WindowIDFn getWindowID;
static void load(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
        if (!handle) return;
        connection=(MainFn)dlsym(handle,"SLSMainConnectionID");
        displays=(DisplaysFn)dlsym(handle,"SLSCopyManagedDisplaySpaces");
        spaceType=(TypeFn)dlsym(handle,"SLSSpaceGetType");
        membership=(MembershipFn)dlsym(handle,"SLSCopySpacesForWindows");
        getWindowID=(WindowIDFn)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    });
}
BOOL WFContext(CGDirectDisplayID display,uint64_t *space,int *type) {
    load(); if (!handle || !connection || !displays || !spaceType) return NO;
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return NO;
    NSString *identifier=CFBridgingRelease(CFUUIDCreateString(NULL,uuid)); CFRelease(uuid);
    NSArray *list=CFBridgingRelease(displays(connection()));
    if (![list isKindOfClass:NSArray.class]) return NO;
    for (id object in list) {
        if (![object isKindOfClass:NSDictionary.class]) return NO;
        NSDictionary *entry=object;
        if (![entry[@"Display Identifier"] isEqual:identifier] && ![entry[@"Display Identifier"] isEqual:@"Main"]) continue;
        id current=entry[@"Current Space"];
        if (![current isKindOfClass:NSDictionary.class]) return NO;
        NSNumber *sid=current[@"ManagedSpaceID"];
        if (![sid isKindOfClass:NSNumber.class] || !sid.unsignedLongLongValue) return NO;
        *space=sid.unsignedLongLongValue; *type=spaceType(connection(),*space); return YES;
    }
    return NO;
}
NSArray *WFWindowSpaces(CGWindowID window) {
    load(); if (!handle || !connection || !membership) return nil;
    CFArrayRef raw=membership(connection(),7,(__bridge CFArrayRef)@[@(window)]);
    NSArray *spaces=CFBridgingRelease(raw);
    if (![spaces isKindOfClass:NSArray.class]) return nil;
    for (id item in spaces) if (![item isKindOfClass:NSNumber.class]) return nil;
    return spaces;
}
CGWindowID WFWindowID(AXUIElementRef window) {
    load(); CGWindowID wid=0;
    return getWindowID && getWindowID(window,&wid)==kAXErrorSuccess ? wid : 0;
}
BOOL WFReadFrame(AXUIElementRef window,CGRect *frame) {
    CFTypeRef p=NULL,s=NULL;
    AXError pe=AXUIElementCopyAttributeValue(window,kAXPositionAttribute,&p);
    AXError se=AXUIElementCopyAttributeValue(window,kAXSizeAttribute,&s);
    CGPoint point; CGSize size;
    BOOL ok=pe==0 && se==0 && p && s && CFGetTypeID(p)==AXValueGetTypeID() && CFGetTypeID(s)==AXValueGetTypeID()
        && AXValueGetValue((AXValueRef)p,kAXValueCGPointType,&point)
        && AXValueGetValue((AXValueRef)s,kAXValueCGSizeType,&size);
    if (p) CFRelease(p); if (s) CFRelease(s);
    if (ok) *frame=(CGRect){point,size}; return ok;
}
AXError WFSetPosition(AXUIElementRef window,CGPoint position) {
    AXValueRef value=AXValueCreate(kAXValueCGPointType,&position);
    AXError error=AXUIElementSetAttributeValue(window,kAXPositionAttribute,value); CFRelease(value); return error;
}
AXError WFSetSize(AXUIElementRef window,CGSize size) {
    AXValueRef value=AXValueCreate(kAXValueCGSizeType,&size);
    AXError error=AXUIElementSetAttributeValue(window,kAXSizeAttribute,value); CFRelease(value); return error;
}

// Scoped Enhanced UI handling follows the Hammerspoon 1.1.1 frame helper.
// Unsupported attributes are left alone; never leave an app's setting changed.
AXError WFApplyDirectFrame(AXUIElementRef window,CGRect frame) {
    CGRect current=CGRectZero;
    if (WFReadFrame(window,&current) && fabs(current.size.width-frame.size.width)<=2
        && fabs(current.size.height-frame.size.height)<=2) return WFSetPosition(window,frame.origin);
    pid_t pid=0; AXUIElementGetPid(window,&pid);
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    CFTypeRef enhanced=NULL; BOOL changed=NO;
    if (AXUIElementCopyAttributeValue(app,CFSTR("AXEnhancedUserInterface"),&enhanced)==kAXErrorSuccess
        && enhanced && CFGetTypeID(enhanced)==CFBooleanGetTypeID() && CFBooleanGetValue(enhanced)) {
        changed=AXUIElementSetAttributeValue(app,CFSTR("AXEnhancedUserInterface"),kCFBooleanFalse)==kAXErrorSuccess;
    }
    AXError first=WFSetSize(window,frame.size);
    AXError position=WFSetPosition(window,frame.origin);
    AXError last=WFSetSize(window,frame.size);
    if (changed) AXUIElementSetAttributeValue(app,CFSTR("AXEnhancedUserInterface"),kCFBooleanTrue);
    if (enhanced) CFRelease(enhanced);
    CFRelease(app);
    return first ? first : position ? position : last;
}

#import <Carbon/Carbon.h>
#import "ShortcutRegistry.h"
static EventHotKeyRef wfKeys[64];
static EventHandlerRef wfHandler;
static WFHotKeyCallback wfKeyCallback;
static void *wfKeyContext;
static OSStatus wfHotKeyEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context;
    EventHotKeyID hotkey={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(hotkey),NULL,&hotkey);
    if(status==noErr && WFHandleShortcutCapture(hotkey)) return noErr;
    if (status!=noErr || hotkey.signature!='WFGC' || !wfKeyCallback) return eventNotHandledErr;
    wfKeyCallback(hotkey.id,wfKeyContext); return noErr;
}
void WFUnregisterHotKeys(void) {
    for (unsigned i=0;i<64;i++) if (wfKeys[i]) { WFUnregisterConfiguredHotKey(wfKeys[i]); wfKeys[i]=NULL; }
    if (wfHandler) { RemoveEventHandler(wfHandler); wfHandler=NULL; }
    wfKeyCallback=NULL; wfKeyContext=NULL;
}
int32_t WFRegisterHotKeys(const uint32_t *keys,const uint32_t *modifiers,uint32_t count,
                         WFHotKeyCallback callback,void *context,uint32_t *failedIndex) {
    WFUnregisterHotKeys(); *failedIndex=0;
    if (!count || count>64) return paramErr;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus result=InstallEventHandler(GetApplicationEventTarget(),wfHotKeyEvent,1,&type,NULL,&wfHandler);
    if (result!=noErr) return result;
    wfKeyCallback=callback; wfKeyContext=context;
    for (uint32_t i=0;i<count;i++) {
        EventHotKeyID id={'WFGC',i};
        result=WFRegisterConfiguredHotKey(keys[i],modifiers[i],id,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfKeys[i]);
        if (result!=noErr) { *failedIndex=i; WFUnregisterHotKeys(); return result; }
    }
    return noErr;
}

// Directional focus has an independent registry and event signature.
static EventHotKeyRef wfFocusKeys[4];
static EventHandlerRef wfFocusHandler;
static WFHotKeyCallback wfFocusCallback;
static void *wfFocusContext;
static OSStatus wfFocusEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if (status!=noErr || key.signature!='WFFC' || !wfFocusCallback) return eventNotHandledErr;
    wfFocusCallback(key.id,wfFocusContext); return noErr;
}
void WFUnregisterFocusHotKeys(void) {
    for(unsigned i=0;i<4;i++) if(wfFocusKeys[i]) { WFUnregisterConfiguredHotKey(wfFocusKeys[i]); wfFocusKeys[i]=NULL; }
    if(wfFocusHandler) { RemoveEventHandler(wfFocusHandler); wfFocusHandler=NULL; }
    wfFocusCallback=NULL; wfFocusContext=NULL;
}
int32_t WFRegisterFocusHotKeys(const uint32_t *keys,uint32_t count,WFHotKeyCallback callback,void *context,uint32_t *failedIndex) {
    WFUnregisterFocusHotKeys(); *failedIndex=0;
    if(count!=4) return paramErr;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfFocusEvent,1,&type,NULL,&wfFocusHandler);
    if(status!=noErr) return status;
    wfFocusCallback=callback; wfFocusContext=context;
    for(unsigned i=0;i<count;i++) {
        EventHotKeyID key={'WFFC',i};
        status=WFRegisterConfiguredHotKey(keys[i],cmdKey|optionKey|controlKey,key,GetApplicationEventTarget(),0,&wfFocusKeys[i]);
        if(status!=noErr) { *failedIndex=i; WFUnregisterFocusHotKeys(); return status; }
    }
    return noErr;
}

int32_t WFRequestWindowFocus(AXUIElementRef window,pid_t pid,int32_t *mainStatus,int32_t *raiseStatus) {
    pid_t actual=0;
    AXError identity=AXUIElementGetPid(window,&actual);
    *mainStatus=kAXErrorFailure; *raiseStatus=kAXErrorFailure;
    if(identity!=kAXErrorSuccess || actual!=pid) return paramErr;
    *mainStatus=AXUIElementSetAttributeValue(window,kAXMainAttribute,kCFBooleanTrue);
    // Raise is useful where supported, but some apps reject it. It must not
    // prevent the front-window activation used by the original Spoon.
    *raiseStatus=AXUIElementPerformAction(window,kAXRaiseAction);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    ProcessSerialNumber psn={0,0};
    OSStatus status=GetProcessForPID(pid,&psn);
    if(status==noErr) status=SetFrontProcessWithOptions(&psn,kSetFrontProcessFrontWindowOnly);
#pragma clang diagnostic pop
    // Preserve the selected window when activation chooses an app's old main
    // window (notably Finder). Space eligibility is enforced by the caller.
    if(status==noErr) AXUIElementSetAttributeValue(window,kAXMainAttribute,kCFBooleanTrue);
    return status;
}

// Independent stash group; leaves geometry and focus registrations untouched.
static EventHotKeyRef wfStashKey;
static EventHandlerRef wfStashHandler;
static WFHotKeyCallback wfStashCallback;
static void *wfStashContext;
static OSStatus wfStashEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if(status!=noErr || key.signature!='WFST' || !wfStashCallback) return eventNotHandledErr;
    wfStashCallback(0,wfStashContext); return noErr;
}
void WFUnregisterStashHotKey(void) {
    if(wfStashKey) { WFUnregisterConfiguredHotKey(wfStashKey); wfStashKey=NULL; }
    if(wfStashHandler) { RemoveEventHandler(wfStashHandler); wfStashHandler=NULL; }
    wfStashCallback=NULL; wfStashContext=NULL;
}
int32_t WFRegisterStashHotKey(WFHotKeyCallback callback,void *context) {
    WFUnregisterStashHotKey(); EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfStashEvent,1,&type,NULL,&wfStashHandler);
    if(status!=noErr) return status;
    wfStashCallback=callback; wfStashContext=context; EventHotKeyID key={'WFST',0};
    status=WFRegisterConfiguredHotKey(1,cmdKey|optionKey|controlKey,key,GetApplicationEventTarget(),0,&wfStashKey);
    if(status!=noErr) WFUnregisterStashHotKey(); return status;
}

// Independent accordion group; leaves all accepted registrations untouched.
static EventHotKeyRef wfAccordionKey;
static EventHandlerRef wfAccordionHandler;
static WFHotKeyCallback wfAccordionCallback;
static void *wfAccordionContext;
static OSStatus wfAccordionEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if(status!=noErr || key.signature!='WFAC' || !wfAccordionCallback) return eventNotHandledErr;
    wfAccordionCallback(0,wfAccordionContext); return noErr;
}
void WFUnregisterAccordionHotKey(void) {
    if(wfAccordionKey) { WFUnregisterConfiguredHotKey(wfAccordionKey); wfAccordionKey=NULL; }
    if(wfAccordionHandler) { RemoveEventHandler(wfAccordionHandler); wfAccordionHandler=NULL; }
    wfAccordionCallback=NULL; wfAccordionContext=NULL;
}
int32_t WFRegisterAccordionHotKey(WFHotKeyCallback callback,void *context) {
    WFUnregisterAccordionHotKey(); EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfAccordionEvent,1,&type,NULL,&wfAccordionHandler);
    if(status!=noErr) return status;
    wfAccordionCallback=callback; wfAccordionContext=context; EventHotKeyID key={'WFAC',0};
    status=WFRegisterConfiguredHotKey(1,cmdKey|optionKey|controlKey|shiftKey,key,GetApplicationEventTarget(),0,&wfAccordionKey);
    if(status!=noErr) WFUnregisterAccordionHotKey(); return status;
}

int32_t WFSpaceKind(uint64_t space) {
    load(); return connection && spaceType ? spaceType(connection(),space) : -1;
}
// Independent switcher registry: W, Shift+W; Escape exists only during a session.
static EventHotKeyRef wfSwitchKeys[6];
static EventHandlerRef wfSwitchHandler;
static WFHotKeyCallback wfSwitchCallback;
static void *wfSwitchContext;
static OSStatus wfSwitchEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if(status!=noErr || key.signature!='WFSW' || !wfSwitchCallback) return eventNotHandledErr;
    wfSwitchCallback(key.id,wfSwitchContext); return noErr;
}
int32_t WFSetSwitcherEscape(BOOL enabled) {
    for(unsigned i=2;i<6;i++) if(wfSwitchKeys[i]) { WFUnregisterConfiguredHotKey(wfSwitchKeys[i]); wfSwitchKeys[i]=NULL; }
    if(!enabled) return noErr;
    UInt32 modifiers[]={0,cmdKey|optionKey|controlKey,cmdKey|optionKey|controlKey|shiftKey,shiftKey};
    for(unsigned i=0;i<4;i++) {
        EventHotKeyID key={'WFSW',2};
        OSStatus status=WFRegisterConfiguredHotKey(53,modifiers[i],key,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfSwitchKeys[i+2]);
        if(status!=noErr) {
            for(unsigned j=2;j<6;j++) if(wfSwitchKeys[j]) { WFUnregisterConfiguredHotKey(wfSwitchKeys[j]); wfSwitchKeys[j]=NULL; }
            return status;
        }
    }
    return noErr;
}
void WFUnregisterSwitcherHotKeys(void) {
    for(unsigned i=0;i<6;i++) if(wfSwitchKeys[i]) { WFUnregisterConfiguredHotKey(wfSwitchKeys[i]); wfSwitchKeys[i]=NULL; }
    if(wfSwitchHandler) { RemoveEventHandler(wfSwitchHandler); wfSwitchHandler=NULL; }
    wfSwitchCallback=NULL; wfSwitchContext=NULL;
}
int32_t WFRegisterSwitcherHotKeys(WFHotKeyCallback callback,void *context,uint32_t *failedIndex) {
    WFUnregisterSwitcherHotKeys(); *failedIndex=0;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfSwitchEvent,1,&type,NULL,&wfSwitchHandler);
    if(status!=noErr) return status;
    wfSwitchCallback=callback; wfSwitchContext=context;
    for(unsigned i=0;i<2;i++) {
        EventHotKeyID key={'WFSW',i};
        status=WFRegisterConfiguredHotKey(13,cmdKey|optionKey|controlKey|(i ? shiftKey : 0),key,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfSwitchKeys[i]);
        if(status!=noErr) { *failedIndex=i; WFUnregisterSwitcherHotKeys(); return status; }
    }
    return noErr;
}

// These switcher-only reads do not alter the accepted groups' membership API.
typedef CFArrayRef (*SwitcherWindowsFn)(int,uint32_t,CFArrayRef,uint32_t,uint64_t *,uint64_t *);
NSArray *WFSwitcherSpaceWindows(uint64_t space,BOOL onlyUp) {
    load(); if(!handle || !connection || !spaceType || !space) return nil;
    SwitcherWindowsFn list=(SwitcherWindowsFn)dlsym(handle,"SLSCopyWindowsWithOptionsAndTags");
    if(!list) return nil;
    uint64_t set=0,clear=0;
    NSArray *result=CFBridgingRelease(list(connection(),0,(__bridge CFArrayRef)@[@(space)],onlyUp ? 2 : 7,&set,&clear));
    if(![result isKindOfClass:NSArray.class]) return nil;
    for(id item in result) if(![item isKindOfClass:NSNumber.class]) return nil;
    return result;
}
NSArray *WFSwitcherSpaces(CGDirectDisplayID display) {
    load(); if(!handle || !connection || !displays || !spaceType) return nil;
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display); if(!uuid) return nil;
    NSString *identifier=CFBridgingRelease(CFUUIDCreateString(NULL,uuid)); CFRelease(uuid);
    NSArray *managed=CFBridgingRelease(displays(connection()));
    if(![managed isKindOfClass:NSArray.class]) return nil;
    for(id object in managed) {
        if(![object isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *d=object;
        if(![d[@"Display Identifier"] isEqual:identifier] && ![d[@"Display Identifier"] isEqual:@"Main"]) continue;
        NSArray *spaces=d[@"Spaces"]; id currentEntry=d[@"Current Space"];
        if(![currentEntry isKindOfClass:NSDictionary.class]) return nil;
        NSNumber *current=currentEntry[@"ManagedSpaceID"];
        if(![spaces isKindOfClass:NSArray.class] || ![current isKindOfClass:NSNumber.class]) return nil;
        NSMutableArray *result=[NSMutableArray array]; unsigned ordinal=0;
        for(id entry in spaces) {
            if(![entry isKindOfClass:NSDictionary.class]) return nil;
            NSNumber *sid=entry[@"ManagedSpaceID"]; if(![sid isKindOfClass:NSNumber.class]) return nil;
            int kind=spaceType(connection(),sid.unsignedLongLongValue);
            if(kind==0) ordinal++;
            [result addObject:@{@"id":sid,@"display":@(display),@"identifier":d[@"Display Identifier"],
                @"ordinal":@(ordinal),@"kind":@(kind),@"shown":@([sid isEqual:current])}];
        }
        return result;
    }
    return nil;
}

#import <objc/message.h>
@interface NSObject (WFSwitcherSpaceInitializers)
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)space;
- (instancetype)initWithSpaces:(NSArray *)spaces;
@end
static BOOL wfPerformSwitcherSpaceOperation(id operation) {
    SEL selector=NSSelectorFromString(@"performWithWMBridgeDelegate");
    NSMethodSignature *signature=[operation methodSignatureForSelector:selector];
    if(!signature || signature.numberOfArguments!=2 || strcmp(signature.methodReturnType,@encode(void))!=0) return NO;
    ((void (*)(id,SEL))(void *)objc_msgSend)(operation,selector); return YES;
}
BOOL WFSwitcherSelectSpace(CGDirectDisplayID display,uint64_t expectedSource,uint64_t destination) {
    uint64_t current=0;int kind=-1;
    if(!WFContext(display,&current,&kind) || current!=expectedSource) return NO;
    if(current==destination) return YES;
    // The existing native helper proved this protocol for ordinary desktops.
    // Full-screen targets with existing AX elements retain native activation.
    if(kind!=0 || WFSpaceKind(destination)!=0) return NO;
    NSDictionary *target=nil;
    for(NSDictionary *space in WFSwitcherSpaces(display)) if([space[@"id"] unsignedLongLongValue]==destination) target=space;
    if(!target) return NO;
    Class setClass=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    Class hideClass=NSClassFromString(@"SLSBridgedHideSpacesOperation");
    if(![setClass instancesRespondToSelector:NSSelectorFromString(@"initWithDisplayIdentifier:spaceID:")]
        || ![hideClass instancesRespondToSelector:NSSelectorFromString(@"initWithSpaces:")]) return NO;
    id set=[[setClass alloc] initWithDisplayIdentifier:target[@"identifier"] spaceID:destination];
    id hide=[[hideClass alloc] initWithSpaces:@[@(expectedSource)]];
    if(!set || !hide) return NO;
    return wfPerformSwitcherSpaceOperation(set) && wfPerformSwitcherSpaceOperation(hide);
}

// Production use of the isolated bridge move-and-follow proof. No legacy
// SLSMoveWindowsToManagedSpace fallback or synthesized keyboard/mouse events.
@interface NSObject (WFSpaceMoveInitializers)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)space;
@end
BOOL WFSpaceMoveAvailable(void) {
    load();
    Class move=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    Class set=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    Class hide=NSClassFromString(@"SLSBridgedHideSpacesOperation");
    return [move instancesRespondToSelector:NSSelectorFromString(@"initWithWindows:spaceID:")]
        && [set instancesRespondToSelector:NSSelectorFromString(@"initWithDisplayIdentifier:spaceID:")]
        && [hide instancesRespondToSelector:NSSelectorFromString(@"initWithSpaces:")];
}
BOOL WFMoveWindowToAdjacentSpace(AXUIElementRef window,pid_t pid,CGDirectDisplayID display,uint64_t source,uint64_t destination) {
    if(!WFSpaceMoveAvailable()) return NO;
    pid_t actual=0; uint64_t current=0; int kind=-1;
    CGWindowID wid=WFWindowID(window);
    if(!wid || AXUIElementGetPid(window,&actual)!=kAXErrorSuccess || actual!=pid
        || !WFContext(display,&current,&kind) || kind!=0 || current!=source
        || ![WFWindowSpaces(wid) isEqual:@[@(source)]]) return NO;
    NSMutableArray *users=[NSMutableArray array];
    for(NSDictionary *entry in WFSwitcherSpaces(display)) if([entry[@"kind"] intValue]==0) [users addObject:entry[@"id"]];
    NSUInteger a=[users indexOfObject:@(source)],b=[users indexOfObject:@(destination)];
    if(a==NSNotFound || b==NSNotFound || !(a+1==b || b+1==a)) return NO;
    Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    id operation=[[cls alloc] initWithWindows:@[@(wid)] spaceID:destination];
    return operation && wfPerformSwitcherSpaceOperation(operation);
}

// Space movement owns its two arrows independently of all accepted groups.
static EventHotKeyRef wfSpaceMoveKeys[2];
static EventHandlerRef wfSpaceMoveHandler;
static WFHotKeyCallback wfSpaceMoveCallback;
static void *wfSpaceMoveContext;
static OSStatus wfSpaceMoveEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if(status!=noErr || key.signature!='WFSM' || key.id>=2 || !wfSpaceMoveCallback) return eventNotHandledErr;
    wfSpaceMoveCallback(key.id,wfSpaceMoveContext); return noErr;
}
void WFUnregisterSpaceMoveHotKeys(void) {
    for(unsigned i=0;i<2;i++) if(wfSpaceMoveKeys[i]) { WFUnregisterConfiguredHotKey(wfSpaceMoveKeys[i]); wfSpaceMoveKeys[i]=NULL; }
    if(wfSpaceMoveHandler) { RemoveEventHandler(wfSpaceMoveHandler); wfSpaceMoveHandler=NULL; }
    wfSpaceMoveCallback=NULL; wfSpaceMoveContext=NULL;
}
int32_t WFRegisterSpaceMoveHotKeys(WFHotKeyCallback callback,void *context,uint32_t *failedIndex) {
    WFUnregisterSpaceMoveHotKeys(); *failedIndex=0;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfSpaceMoveEvent,1,&type,NULL,&wfSpaceMoveHandler);
    if(status!=noErr) return status;
    wfSpaceMoveCallback=callback; wfSpaceMoveContext=context;
    const UInt32 keys[]={123,124};
    for(unsigned i=0;i<2;i++) {
        EventHotKeyID key={'WFSM',i};
        status=WFRegisterConfiguredHotKey(keys[i],cmdKey|optionKey|controlKey,key,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfSpaceMoveKeys[i]);
        if(status!=noErr) { *failedIndex=i; WFUnregisterSpaceMoveHotKeys(); return status; }
    }
    return noErr;
}

// Native library launcher has its own registry; Shift+R stays with Hammerspoon.
static EventHotKeyRef wfLauncherKeys[2];
static EventHandlerRef wfLauncherHandler;
static WFHotKeyCallback wfLauncherCallback;
static void *wfLauncherContext;
static OSStatus wfLauncherEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next; (void)context; EventHotKeyID key={0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(status==noErr && WFHandleShortcutCapture(key)) return noErr;
    if(status!=noErr || key.signature!='WFLA' || !wfLauncherCallback) return eventNotHandledErr;
    wfLauncherCallback(key.id,wfLauncherContext); return noErr;
}
void WFUnregisterLauncherHotKey(void) {
    for(unsigned i=0;i<2;i++) if(wfLauncherKeys[i]) { WFUnregisterConfiguredHotKey(wfLauncherKeys[i]); wfLauncherKeys[i]=NULL; }
    if(wfLauncherHandler) { RemoveEventHandler(wfLauncherHandler); wfLauncherHandler=NULL; }
    wfLauncherCallback=NULL; wfLauncherContext=NULL;
}
int32_t WFRegisterLauncherHotKey(WFHotKeyCallback callback,void *context) {
    WFUnregisterLauncherHotKey(); EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfLauncherEvent,1,&type,NULL,&wfLauncherHandler);
    if(status!=noErr) return status;
    wfLauncherCallback=callback; wfLauncherContext=context;
    const UInt32 keys[]={15,44};
    for(unsigned i=0;i<2;i++) {
        EventHotKeyID key={'WFLA',i};
        status=WFRegisterConfiguredHotKey(keys[i],cmdKey|optionKey|controlKey,key,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfLauncherKeys[i]);
        if(status!=noErr) { WFUnregisterLauncherHotKey(); return status; }
    }
    return noErr;
}

#import "ApplicationHotKeys.h"
