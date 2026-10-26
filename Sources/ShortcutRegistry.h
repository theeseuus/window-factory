// Shared hotkey plumbing only. Existing command callbacks and window logic stay
// in their original owners. Test builds replace just the two Carbon operations.
#ifndef WF_REGISTER_OS_HOTKEY
#define WF_REGISTER_OS_HOTKEY RegisterEventHotKey
#define WF_UNREGISTER_OS_HOTKEY UnregisterEventHotKey
#endif
#define WF_SHORTCUT_LIMIT 128
static struct {
    BOOL active;
    EventHotKeyID id;
    UInt32 originalKey,originalModifiers,key,modifiers;
    EventTargetRef target;
    OptionBits options;
    EventHotKeyRef *slot;
} wfTracked[WF_SHORTCUT_LIMIT];
static struct { UInt32 signature,index,key,modifiers; } wfOverrides[64];
static uint32_t wfOverrideCount;
static WFShortcutCaptureCallback wfCapture;
static void *wfCaptureContext;
static void wfEffectiveShortcut(EventHotKeyID id,UInt32 *key,UInt32 *modifiers) {
    for(uint32_t i=0;i<wfOverrideCount;i++) if(wfOverrides[i].signature==id.signature && wfOverrides[i].index==id.id) {
        *key=wfOverrides[i].key; *modifiers=wfOverrides[i].modifiers; return;
    }
}
static OSStatus WFRegisterConfiguredHotKey(UInt32 key,UInt32 modifiers,EventHotKeyID id,EventTargetRef target,OptionBits options,EventHotKeyRef *slot) {
    unsigned index=WF_SHORTCUT_LIMIT;
    for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) {
        if(wfTracked[i].active && wfTracked[i].id.signature==id.signature && wfTracked[i].id.id==id.id && wfTracked[i].slot==slot) {
            if(wfTracked[i].slot && *wfTracked[i].slot) return paramErr;
            index=i; break;
        }
        if(!wfTracked[i].active && index==WF_SHORTCUT_LIMIT) index=i;
    }
    if(index==WF_SHORTCUT_LIMIT) return memFullErr;
    UInt32 effectiveKey=key,effectiveModifiers=modifiers;
    wfEffectiveShortcut(id,&effectiveKey,&effectiveModifiers);
    OSStatus status=WF_REGISTER_OS_HOTKEY(effectiveKey,effectiveModifiers,id,target,options,slot);
    if(status==noErr) {
        wfTracked[index].active=YES; wfTracked[index].id=id;
        wfTracked[index].originalKey=key; wfTracked[index].originalModifiers=modifiers;
        wfTracked[index].key=effectiveKey; wfTracked[index].modifiers=effectiveModifiers;
        wfTracked[index].target=target; wfTracked[index].options=options; wfTracked[index].slot=slot;
    }
    return status;
}
static OSStatus WFUnregisterConfiguredHotKey(EventHotKeyRef key) {
    OSStatus status=WF_UNREGISTER_OS_HOTKEY(key);
    for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].slot && *wfTracked[i].slot==key) {
        wfTracked[i].active=NO; *wfTracked[i].slot=NULL;
    }
    return status;
}
void WFSetShortcutCapture(WFShortcutCaptureCallback callback,void *context) { wfCapture=callback; wfCaptureContext=context; }
static BOOL WFHandleShortcutCapture(EventHotKeyID id) {
    if(!wfCapture) return NO;
    for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].id.signature==id.signature && wfTracked[i].id.id==id.id) {
        wfCapture(wfTracked[i].key,wfTracked[i].modifiers,wfCaptureContext); return YES;
    }
    return NO;
}
static BOOL wfValidShortcutSlot(UInt32 signature,UInt32 index) {
    switch(signature) {
        case 'WFGC': return index<19;
        case 'WFFC': return index<4;
        case 'WFSW': case 'WFSM': return index<2;
        case 'WFLA': return index<2;
        case 'WFST': case 'WFAC': return index==0;
        default: return NO;
    }
}
// No callbacks are removed. On failure, restore every prior registration and
// return rollback status separately; callers never save a rejected draft.
int32_t WFUpdateShortcutConfiguration(const uint32_t *signatures,const uint32_t *indices,const uint32_t *keys,const uint32_t *modifiers,uint32_t count,uint32_t *failedIndex,int32_t *rollbackStatus) {
    *failedIndex=0; *rollbackStatus=noErr;
    if(count>64) return paramErr;
    for(uint32_t i=0;i<count;i++) {
        *failedIndex=i;
        if(!wfValidShortcutSlot(signatures[i],indices[i]) || keys[i]>127 || (modifiers[i]&~(cmdKey|optionKey|controlKey|shiftKey))) return paramErr;
        for(uint32_t j=0;j<i;j++) if(signatures[j]==signatures[i] && indices[j]==indices[i]) return paramErr;
    }
    typeof(wfOverrides) oldOverrides; memcpy(oldOverrides,wfOverrides,sizeof(wfOverrides));
    uint32_t oldCount=wfOverrideCount;
    OSStatus status=noErr;
    for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].slot && *wfTracked[i].slot) {
        OSStatus released=WF_UNREGISTER_OS_HOTKEY(*wfTracked[i].slot);
        if(released==noErr) *wfTracked[i].slot=NULL;
        else if(status==noErr) status=released;
    }
    if(status==noErr) {
        wfOverrideCount=count;
        for(uint32_t i=0;i<count;i++) {
            wfOverrides[i].signature=signatures[i]; wfOverrides[i].index=indices[i];
            wfOverrides[i].key=keys[i]; wfOverrides[i].modifiers=modifiers[i];
        }
        for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].slot) {
            UInt32 key=wfTracked[i].originalKey,mods=wfTracked[i].originalModifiers;
            wfEffectiveShortcut(wfTracked[i].id,&key,&mods);
            status=WF_REGISTER_OS_HOTKEY(key,mods,wfTracked[i].id,wfTracked[i].target,wfTracked[i].options,wfTracked[i].slot);
            if(status!=noErr) {
                for(uint32_t j=0;j<count;j++) if(signatures[j]==wfTracked[i].id.signature && indices[j]==wfTracked[i].id.id) *failedIndex=j;
                break;
            }
            wfTracked[i].key=key; wfTracked[i].modifiers=mods;
        }
        if(status==noErr) return noErr;
        for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].slot && *wfTracked[i].slot) {
            WF_UNREGISTER_OS_HOTKEY(*wfTracked[i].slot); *wfTracked[i].slot=NULL;
        }
    }
    memcpy(wfOverrides,oldOverrides,sizeof(wfOverrides)); wfOverrideCount=oldCount;
    for(unsigned i=0;i<WF_SHORTCUT_LIMIT;i++) if(wfTracked[i].active && wfTracked[i].slot && !*wfTracked[i].slot) {
        UInt32 key=wfTracked[i].originalKey,mods=wfTracked[i].originalModifiers;
        wfEffectiveShortcut(wfTracked[i].id,&key,&mods);
        OSStatus restored=WF_REGISTER_OS_HOTKEY(key,mods,wfTracked[i].id,wfTracked[i].target,wfTracked[i].options,wfTracked[i].slot);
        if(restored!=noErr && *rollbackStatus==noErr) *rollbackStatus=restored;
        wfTracked[i].key=key; wfTracked[i].modifiers=mods;
    }
    return status;
}
