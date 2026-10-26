// Independent app/optional-command keys: window-control slots are never released.
#define WF_APP_KEY_LIMIT 67 // 0 search, 1...64 apps, 65 new window, 66 tiling controls
static struct { EventHotKeyRef ref; UInt32 key,mods; WFHotKeyCallback callback; void *context; } wfAppKeys[WF_APP_KEY_LIMIT];
static EventHandlerRef wfAppHandler;
static OSStatus wfAppEvent(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;(void)context;EventHotKeyID id;
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(id),NULL,&id);
    if(status!=noErr || id.signature!='WFAP' || id.id>=WF_APP_KEY_LIMIT || !wfAppKeys[id.id].ref) return eventNotHandledErr;
    if(wfCapture) {wfCapture(wfAppKeys[id.id].key,wfAppKeys[id.id].mods,wfCaptureContext);return noErr;}
    if(wfAppKeys[id.id].callback)wfAppKeys[id.id].callback(id.id,wfAppKeys[id.id].context);return noErr;
}
int32_t WFConfigureApplicationHotKey(uint32_t index,uint32_t key,uint32_t modifiers,BOOL enabled,WFHotKeyCallback callback,void *context,int32_t *rollback) {
    *rollback=noErr;
    if(index>=WF_APP_KEY_LIMIT || key>127 || (modifiers&~(cmdKey|optionKey|controlKey|shiftKey)))return paramErr;
    if(enabled && !wfAppHandler){EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};OSStatus status=InstallEventHandler(GetApplicationEventTarget(),wfAppEvent,1,&type,NULL,&wfAppHandler);if(status!=noErr)return status;}
    EventHotKeyRef old=wfAppKeys[index].ref;UInt32 oldKey=wfAppKeys[index].key,oldMods=wfAppKeys[index].mods;
    if(old){OSStatus status=WF_UNREGISTER_OS_HOTKEY(old);if(status!=noErr)return status;wfAppKeys[index].ref=NULL;}
    OSStatus status=noErr;EventHotKeyID id={'WFAP',index};
    if(enabled)status=WF_REGISTER_OS_HOTKEY(key,modifiers,id,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfAppKeys[index].ref);
    if(status!=noErr){if(old)*rollback=WF_REGISTER_OS_HOTKEY(oldKey,oldMods,id,GetApplicationEventTarget(),kEventHotKeyExclusive,&wfAppKeys[index].ref);return status;}
    wfAppKeys[index].key=key;wfAppKeys[index].mods=modifiers;wfAppKeys[index].callback=callback;wfAppKeys[index].context=context;return noErr;
}
void WFStopApplicationHotKeys(void) {
    for(unsigned i=0;i<WF_APP_KEY_LIMIT;i++)if(wfAppKeys[i].ref){WF_UNREGISTER_OS_HOTKEY(wfAppKeys[i].ref);wfAppKeys[i].ref=NULL;}
    if(wfAppHandler){RemoveEventHandler(wfAppHandler);wfAppHandler=NULL;}
}
