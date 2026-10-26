#import <Carbon/Carbon.h>
#import "../Sources/Bridge.h"
#include <assert.h>
#include <string.h>
static struct { BOOL used; UInt32 key,mods; } fake[256];
static int blockedKey=-1,blockedKey2=-1,failRelease=-1;
static OSStatus reg(UInt32 key,UInt32 mods,EventHotKeyID id,EventTargetRef target,OptionBits options,EventHotKeyRef *out) {
    (void)id;(void)target;(void)options;
    if((int)key==blockedKey || (int)key==blockedKey2) return eventHotKeyExistsErr;
    for(int i=1;i<256;i++) if(fake[i].used && fake[i].key==key && fake[i].mods==mods) return eventHotKeyExistsErr;
    for(int i=1;i<256;i++) if(!fake[i].used) { fake[i].used=YES;fake[i].key=key;fake[i].mods=mods;*out=(EventHotKeyRef)(uintptr_t)i;return noErr; }
    return memFullErr;
}
static OSStatus unreg(EventHotKeyRef ref) {
    int i=(int)(uintptr_t)ref;
    if(i==failRelease) { failRelease=-1;return paramErr; }
    if(!i || !fake[i].used) return paramErr;
    fake[i].used=NO;return noErr;
}
#define WF_REGISTER_OS_HOTKEY reg
#define WF_UNREGISTER_OS_HOTKEY unreg
#import "../Sources/ShortcutRegistry.h"
#import "../Sources/ApplicationHotKeys.h"
static UInt32 captured;
static void appInvoke(uint32_t index,void *context) { (void)index;(void)context; }
static void commandInvoke(uint32_t index,void *context) { *(UInt32 *)context=index; }
static void capture(uint32_t key,uint32_t mods,void *context) { (void)mods;(void)context;captured=key; }
int main(void) {
    EventHotKeyRef a=NULL,b=NULL,escape[4]={NULL};
    UInt32 sig[2]={'WFLA','WFST'},idx[2]={0,0},keys[2]={79,1},mods[2]={cmdKey|controlKey|optionKey,cmdKey|controlKey|optionKey},failed=0;int32_t rollback=0;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)==noErr);
    assert(WFRegisterConfiguredHotKey(15,mods[0],(EventHotKeyID){'WFLA',0},NULL,0,&a)==noErr);
    assert(fake[(uintptr_t)a].key==79);
    assert(WFRegisterConfiguredHotKey(1,mods[1],(EventHotKeyID){'WFST',0},NULL,0,&b)==noErr);
    for(int i=0;i<4;i++) assert(WFRegisterConfiguredHotKey(53,(UInt32)i,(EventHotKeyID){'WFSW',2},NULL,0,&escape[i])==noErr);
    keys[0]=80;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)==noErr);
    assert(fake[(uintptr_t)a].key==80 && fake[(uintptr_t)b].key==1);
    blockedKey=81;keys[0]=81;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)!=noErr && rollback==0);
    assert(fake[(uintptr_t)a].key==80 && fake[(uintptr_t)b].key==1);
    blockedKey=-1;failRelease=(int)(uintptr_t)b;keys[0]=82;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)!=noErr && rollback==0);
    assert(fake[(uintptr_t)a].key==80 && fake[(uintptr_t)b].key==1);
    WFSetShortcutCapture(capture,NULL);
    assert(WFHandleShortcutCapture((EventHotKeyID){'WFLA',0}) && captured==80);
    WFSetShortcutCapture(NULL,NULL);
    assert(!WFHandleShortcutCapture((EventHotKeyID){'WFLA',0}));
    assert(WFUnregisterConfiguredHotKey(b)==noErr && !b && a);
    assert(WFUnregisterConfiguredHotKey(a)==noErr && !a);
    for(int i=0;i<4;i++) assert(WFUnregisterConfiguredHotKey(escape[i])==noErr && !escape[i]);
    // Failed recovery is reported separately, rather than claiming old keys work.
    assert(WFRegisterConfiguredHotKey(15,mods[0],(EventHotKeyID){'WFLA',0},NULL,0,&a)==noErr);
    blockedKey=80;blockedKey2=81;keys[0]=81;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)!=noErr && rollback!=noErr && !a);
    blockedKey=-1;blockedKey2=-1;
    assert(WFRegisterConfiguredHotKey(15,mods[0],(EventHotKeyID){'WFLA',0},NULL,0,&a)==noErr);
    keys[0]=200;
    assert(WFUpdateShortcutConfiguration(sig,idx,keys,mods,2,&failed,&rollback)==paramErr);
    assert(a); blockedKey=-1;assert(WFUnregisterConfiguredHotKey(a)==noErr);
    EventHotKeyRef reference=NULL;
    UInt32 referenceSig='WFLA',referenceIndex=1,referenceKey=44,referenceModifiers=cmdKey|controlKey|optionKey;
    assert(WFUpdateShortcutConfiguration(&referenceSig,&referenceIndex,&referenceKey,&referenceModifiers,1,&failed,&rollback)==noErr);
    assert(WFRegisterConfiguredHotKey(44,referenceModifiers,(EventHotKeyID){'WFLA',1},NULL,0,&reference)==noErr);
    WFSetShortcutCapture(capture,NULL);assert(WFHandleShortcutCapture((EventHotKeyID){'WFLA',1}) && captured==44);
    WFSetShortcutCapture(NULL,NULL);assert(WFUnregisterConfiguredHotKey(reference)==noErr);
    // The independent app owner must not release or rewrite any fixed control.
    assert(WFRegisterConfiguredHotKey(44,referenceModifiers,(EventHotKeyID){'WFLA',1},NULL,0,&reference)==noErr);
    int32_t appRollback=0;
    assert(WFConfigureApplicationHotKey(1,17,mods[0],YES,appInvoke,&captured,&appRollback)==noErr);
    EventHotKeyRef appKey=wfAppKeys[1].ref;
    assert(fake[(uintptr_t)appKey].key==17);
    blockedKey=82;
    assert(WFConfigureApplicationHotKey(1,82,mods[0],YES,appInvoke,&captured,&appRollback)!=noErr && appRollback==0);
    assert(fake[(uintptr_t)wfAppKeys[1].ref].key==17);
    blockedKey=-1;
    UInt32 commandResult=0;
    assert(WFConfigureApplicationHotKey(65,16,mods[0],YES,commandInvoke,&commandResult,&appRollback)==noErr);
    assert(wfAppKeys[1].callback==appInvoke && wfAppKeys[1].context==&captured);
    assert(wfAppKeys[65].callback==commandInvoke && wfAppKeys[65].context==&commandResult);
    wfAppKeys[65].callback(65,wfAppKeys[65].context);assert(commandResult==65);
    UInt32 tilingResult=0;
    assert(WFConfigureApplicationHotKey(66,32,mods[0],YES,commandInvoke,&tilingResult,&appRollback)==noErr);
    wfAppKeys[66].callback(66,wfAppKeys[66].context);assert(tilingResult==66 && commandResult==65);
    blockedKey=82;
    assert(WFConfigureApplicationHotKey(65,82,mods[0],YES,commandInvoke,&commandResult,&appRollback)!=noErr && appRollback==0);
    assert(fake[(uintptr_t)wfAppKeys[65].ref].key==16 && wfAppKeys[1].ref);
    blockedKey=-1;
    assert(WFConfigureApplicationHotKey(67,0,mods[0],YES,appInvoke,&captured,&appRollback)==paramErr);
    assert(WFConfigureApplicationHotKey(65,16,mods[0],NO,commandInvoke,&commandResult,&appRollback)==noErr);
    assert(wfAppKeys[1].ref && wfAppKeys[66].ref && reference);
    assert(WFConfigureApplicationHotKey(1,17,mods[0],NO,appInvoke,&captured,&appRollback)==noErr);
    WFStopApplicationHotKeys();
    assert(reference && fake[(uintptr_t)reference].key==44);assert(WFUnregisterConfiguredHotKey(reference)==noErr);
    puts("native shortcut registry: configured/live bindings, capture, shared Escape IDs, rejection and rollback passed; no OS hotkeys registered");
}
