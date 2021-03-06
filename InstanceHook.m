//
//  InstanceHook.m
//  InstanceHook
//
//  Created by Andrew Richardson on 2013-04-02.
//  Copyright (c) 2013 Andrew Richardson. All rights reserved.
//

#import "InstanceHook.h"
#import <CoreFoundation/CoreFoundation.h>
#import <libkern/OSAtomic.h>

#define IHCacheCast(obj) IHBridgeCast(const void *, obj)
#define log_err(fmt...) printf("instance_hook error: " fmt)

static OSSpinLock lock;
static CFMutableDictionaryRef DynamicSubclassesByObject;
static CFMutableDictionaryRef InstanceHooksByObject;

struct _instance_hook_s {
	__unsafe_unretained id obj;
	SEL cmd;
	IMP method;
	IMP origMethod;
	instance_hook_t nextHook;
	int retainCount;
	unsigned validHook:1;
};

static inline char *_instance_hook_copy_description(instance_hook_t hook)
{
	const char *methodName = sel_getName(hook->cmd);
	size_t pointerSize = (sizeof(uintptr_t) * 2) + 3; // add 2 for 0x, 1 for null terminator
	const char *formatString = "<instance_hook %p> (object: %p, method: %s, valid: %d)";
	char *description = malloc(strlen(formatString) + 2*pointerSize + 1 + strlen(methodName));
	sprintf(description, formatString, hook, hook->obj, methodName, hook->validHook);
	return description;
}

// caller should have acquired lock before calling
static inline void _push_hook(instance_hook_t hook)
{
	CFMutableDictionaryRef hooksByMethod = (CFMutableDictionaryRef)CFDictionaryGetValue(InstanceHooksByObject, IHCacheCast(hook->obj));
	if (!hooksByMethod) {
		hooksByMethod = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
		CFDictionarySetValue(InstanceHooksByObject, IHCacheCast(hook->obj), hooksByMethod);
	}
	instance_hook_t nextHook = (instance_hook_t)CFDictionaryGetValue(hooksByMethod, hook->cmd);
	if (nextHook) hook->nextHook = nextHook;
	CFDictionarySetValue(hooksByMethod, hook->cmd, hook);
}

static void _instance_hook_destroy(instance_hook_t hook)
{
	if (!InstanceHooksByObject || !hook || !hook->validHook) return;
	
	OSSpinLockLock(&lock);
	
	hook->validHook = 0;
	CFMutableDictionaryRef hooksByMethod = (CFMutableDictionaryRef)CFDictionaryGetValue(InstanceHooksByObject, IHCacheCast(hook->obj));
	Class cls = CFDictionaryGetValue(DynamicSubclassesByObject, IHCacheCast(hook->obj));
	instance_hook_t topHook = NULL;
	if ((topHook = (instance_hook_t)CFDictionaryGetValue(hooksByMethod, hook->cmd))) {
		if (topHook != hook) {
			instance_hook_t previous = topHook;
			while (previous && previous->nextHook != hook)
				previous = previous->nextHook;
			if (previous) {
				previous->nextHook = hook->nextHook;
				if (previous->origMethod == hook->method)
					previous->origMethod = hook->origMethod;
			}
			else {
				char *desc = _instance_hook_copy_description(hook);
				log_err("Could not find hook %s in lookup table\n", desc);
				free(desc);
			}
		}
		else {
			if (hook->nextHook)
				CFDictionarySetValue(hooksByMethod, hook->cmd, hook->nextHook);
			else
				CFDictionaryRemoveValue(hooksByMethod, hook->cmd);
			Method method = class_getInstanceMethod(cls, hook->cmd);
			method_setImplementation(method, hook->origMethod);
		}
	}
	
	if (hooksByMethod && !CFDictionaryGetCount(hooksByMethod)) {
		CFDictionaryRemoveValue(DynamicSubclassesByObject, IHCacheCast(hook->obj));
		object_setClass(hook->obj, class_getSuperclass(cls));
		objc_disposeClassPair(cls);
	}
	
	OSSpinLockUnlock(&lock);
}

instance_hook_t instance_hook_retain(instance_hook_t hook)
{
	if (hook) hook->retainCount++;
	return hook;
}

void instance_hook_release(instance_hook_t hook)
{
	if (!hook) return;
	if (hook->retainCount-- <= 0) {
		if (hook->validHook) _instance_hook_destroy(hook);
		free(hook);
	}
}

BOOL instance_hook_is_valid(instance_hook_t hook)
{
	return (hook && hook->validHook);
}

void instance_hook_remove(instance_hook_t hook)
{
	_instance_hook_destroy(hook);
	instance_hook_release(hook);
}

IHIMP instance_hook_get_orig(instance_hook_t hook)
{
	return hook ? (IHIMP)hook->origMethod : NULL;
}

static inline void _class_hookMethod(Class cls, Method method, IMP newImp)
{
	BOOL success = class_addMethod(cls, method_getName(method), newImp, method_getTypeEncoding(method));
	if (!success) {
		// class already has implementation, hook it instead
		method_setImplementation(method, newImp);
	}
}

static BOOL _hook_instance(instance_hook_t hook) // where the magic happens
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		DynamicSubclassesByObject = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
		InstanceHooksByObject = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
	});
	
	id obj = hook->obj;
	SEL cmd = hook->cmd;
	IMP newImp = hook->method;
	
	Class cls = object_getClass(obj);
	Method oldMethod = class_getInstanceMethod(cls, cmd);
	if (!oldMethod) return NO;
	
	OSSpinLockLock(&lock);
	
	Class newCls = Nil;
	BOOL success = YES;
	if (!(newCls = CFDictionaryGetValue(DynamicSubclassesByObject, IHCacheCast(obj)))) {
		const char *clsName = class_getName(cls);
		
		// convert address into string
		char address[sizeof(uintptr_t) * 2 + 1]; // add 1 for null terminator
		sprintf(address, "%lx", (uintptr_t)obj);
		
		static const char *suffix = "_DynamicHook";
		char newClsName[strlen(clsName) + strlen(suffix) + sizeof(address)];
		strcpy(newClsName, clsName);
		strcat(newClsName, suffix);
		strcat(newClsName, address);
		
		if (objc_lookUpClass(newClsName)) {
			log_err("Class %s already exists!\n", newClsName);
			success = NO;
		}
		
		if (success) {
			newCls = objc_allocateClassPair(cls, newClsName, 0);
			if (!newCls) {
				log_err("Could not create class %s\n", newClsName);
				success = NO;
			}
			
			if (success) {
				objc_registerClassPair(newCls);
				CFDictionarySetValue(DynamicSubclassesByObject, IHCacheCast(obj), IHCacheCast(newCls));
				
				Method classMethod = class_getInstanceMethod(newCls, @selector(class));
				id hookedClass = ^Class(__unsafe_unretained id self){
					return cls;
				};
				_class_hookMethod(newCls, classMethod, imp_implementationWithBlock(hookedClass));
			}
		}
	}
	
	if (success) {
		hook->origMethod = method_getImplementation(oldMethod);
		_class_hookMethod(newCls, oldMethod, newImp);
		
#ifdef IHUseARC
		// ARC forbids use of @selector(dealloc) for unbelievably stupid reasons
		static SEL deallocSel;
		if (!deallocSel) deallocSel = sel_getUid("dealloc");
#else
		SEL deallocSel = @selector(dealloc);
#endif
		Method dealloc = class_getInstanceMethod(newCls, deallocSel);
		IHIMP deallocImp = (IHIMP)method_getImplementation(dealloc);
		id deallocHandler = ^(__unsafe_unretained id self){
			_instance_hook_destroy(hook);
			hook->obj = nil;
			if (deallocImp) deallocImp(self, deallocSel);
		};
		_class_hookMethod(newCls, dealloc, imp_implementationWithBlock(deallocHandler));
		
		object_setClass(obj, newCls);
		_push_hook(hook);
	}
	
	OSSpinLockUnlock(&lock);
	return success;
}

instance_hook_t instance_hook_create(id self, SEL cmd, id block)
{
	if (!block) return NULL;
	return instance_hook_create_f(self, cmd, imp_implementationWithBlock(block));
}

instance_hook_t instance_hook_create_f(id self, SEL cmd, IMP imp)
{
	if (!self || !cmd || !imp) return NULL;
	
	instance_hook_t hook = malloc(sizeof(struct _instance_hook_s));
	hook->retainCount = 1;
	hook->cmd = cmd;
	hook->obj = self;
	hook->method = imp;
	hook->nextHook = NULL;
	hook->origMethod = NULL;
	hook->validHook = (int)_hook_instance(hook);
	
	return hook;
}

static CFMutableDictionaryRef InstanceHooksByToken;
instance_hook_t instance_hook_get_hook(instance_hook_token_t *token, __unsafe_unretained id self)
{
	if (!InstanceHooksByToken || !token) return NULL;
	CFMutableDictionaryRef objectsForToken = (CFMutableDictionaryRef)CFDictionaryGetValue(InstanceHooksByToken, token);
	if (!objectsForToken) return NULL;
	return (instance_hook_t)CFDictionaryGetValue(objectsForToken, IHCacheCast(self));
}

void instance_hook_perform_block(id self, SEL cmd, id blockHook, void (^block)(), instance_hook_token_t *token)
{
	if (!blockHook || !block) return;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		InstanceHooksByToken = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
	});
	
	instance_hook_t h = instance_hook_create(self, cmd, blockHook);
	CFMutableDictionaryRef objectsForToken;
	if (h) {
		objectsForToken = (CFMutableDictionaryRef)CFDictionaryGetValue(InstanceHooksByToken, token);
		if (!objectsForToken) {
			objectsForToken = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
			CFDictionarySetValue(InstanceHooksByToken, token, objectsForToken);
		}
		if (CFDictionaryContainsKey(objectsForToken, IHCacheCast(self)))
			log_err("token %p already has an associated hook for object %p!\n", token, self);
		CFDictionarySetValue(objectsForToken, IHCacheCast(self), h);
	}
	block();
	if (h) {
		instance_hook_remove(h);
		CFDictionaryRemoveValue(objectsForToken, IHCacheCast(self));
		if (!CFDictionaryGetCount(objectsForToken))
			CFDictionaryRemoveValue(InstanceHooksByToken, token);
	}
}