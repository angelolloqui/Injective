//
//  IJContext.m
//  Injective
//
//  Created by Vladimir Pouzanov on 1/21/12.
//
//  Copyright (c) 2012 Vladimir Pouzanov.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to 
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or 
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//  IN THE SOFTWARE.

#import "IJContext.h"
#import "IJClassRegistration.h"
#import <objc/runtime.h>

static IJContext *DefaultContext = nil;


@interface IJContext ()

- (id)createClassInstanceFromRegistration:(IJClassRegistration *)reg withProperties:(NSDictionary *)props;
- (NSDictionary *)createPropertiesMapForClass:(Class)klass;
- (void)registerClass:(Class)klass forClassName:(NSString *)klassName instantiationMode:(IJContextInstantiationMode)mode instantiationBlock:(IJContextInstantiationBlock)block;
- (NSSet *)gatherPropertiesForKlass:(Class)klass;
- (void)bindRegisteredPropertiesWithRegistration:(IJClassRegistration *)reg toInstance:(id)instance;
- (void)registerProtocolsForClass:(Class)klass;
- (void)registerProtocolNamed:(NSString *)name forClass:(Class)klass;
- (void)registerOnAwakeFromNibForClass:(Class)klass;

@end


@implementation IJContext
{
	NSMutableDictionary *_registeredProtocols;
	NSMutableDictionary *_registeredClasses;
	NSMutableDictionary *_registeredClassesSingletonInstances;
	dispatch_queue_t _queue;
}

+ (IJContext *)defaultContext
{
	if(DefaultContext == nil)
		[NSException raise:NSInternalInconsistencyException format:@"Requested default Injective context, when none is available"];
	return DefaultContext;
}

+ (void)setDefaultContext:(IJContext *)context
{
	if(DefaultContext != context) {
		[DefaultContext release];
		DefaultContext = [context retain];
	}
}

- (id)init
{
    if( (self = [super init]) ) {
		_registeredProtocols = [[NSMutableDictionary alloc] init];
		_registeredClasses = [[NSMutableDictionary alloc] init];
		_registeredClassesSingletonInstances = [[NSMutableDictionary alloc] init];
		NSString *queueName = [NSString stringWithFormat:@"net.farcaller.injective.%p.main", self];
		_queue = dispatch_queue_create([queueName cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_SERIAL);
	}
    return self;
}

- (void)dealloc
{
	[_registeredClasses release];
	[_registeredClassesSingletonInstances release];
	dispatch_release(_queue);
	[super dealloc];
}

- (void)registerOnAwakeFromNib
{
	Class clsNSObject = objc_getClass("NSObject");
	[self registerOnAwakeFromNibForClass:clsNSObject];
	
	// XXX: -[UIViewController awakeFromNib] does NOT call super as of iOS 5.1
	Class clsUIViewController = objc_getClass("UIViewController");
	if(clsUIViewController) {
		// XXX: not available on macs obviously
		[self registerOnAwakeFromNibForClass:clsUIViewController];
	}
}

- (void)registerOnAwakeFromNibForClass:(Class)klass
{
	Method methAwakeFromNib = class_getInstanceMethod(klass, @selector(awakeFromNib));
	typedef void (*send_type)(void*, SEL);
	send_type impOrigAwakeFromNib = (send_type)method_getImplementation(methAwakeFromNib);
	
	IMP impInjAwakeFromNib = imp_implementationWithBlock([[^(id b_self){
		impOrigAwakeFromNib(b_self, @selector(awakeFromNib));
		
		__block IJClassRegistration *reg = nil;
		NSString *klassName = NSStringFromClass([b_self class]);
		
		dispatch_sync(_queue, ^{
			reg = [_registeredClasses objectForKey:klassName];
		});
		
		if(reg) {
			[self bindRegisteredPropertiesWithRegistration:reg toInstance:b_self];
		}
	} copy] autorelease]);
	
	method_setImplementation(methAwakeFromNib, impInjAwakeFromNib);
}

- (void)registerClass:(Class)klass instantiationMode:(IJContextInstantiationMode)mode
{
	[self registerClass:klass instantiationMode:mode instantiationBlock:nil];
}

- (void)registerClass:(Class)klass instantiationMode:(IJContextInstantiationMode)mode instantiationBlock:(IJContextInstantiationBlock)block
{
	NSString *klassName = NSStringFromClass(klass);
	[self registerClass:klass forClassName:klassName instantiationMode:mode instantiationBlock:block];
}

- (void)registerClass:(Class)klass forClassName:(NSString *)klassName instantiationMode:(IJContextInstantiationMode)mode instantiationBlock:(IJContextInstantiationBlock)block
{
	dispatch_async(_queue, ^{
		if([_registeredClasses objectForKey:klassName]) {
			[NSException raise:NSInternalInconsistencyException format:@"Tried to register class %@ that is already registered in the injective context: %@", klass, self];
		}
		IJClassRegistration *reg = [IJClassRegistration registrationWithClass:klass instantiationMode:mode instantiationBlock:block];
		[_registeredClasses setObject:reg forKey:klassName];
		[self registerProtocolsForClass:klass];
	});
}

- (void)registerProtocolsForClass:(Class)klass
{
	unsigned int protocolCount = 0;
	Protocol **protocolList = class_copyProtocolList(klass, &protocolCount);
	
	for(unsigned int i = 0; i < protocolCount; ++i) {
		Protocol *p = protocolList[i];
		NSString *pname = NSStringFromProtocol(p);
		[self registerProtocolNamed:pname forClass:klass];
	}
	
	free(protocolList);
}

- (void)registerProtocolNamed:(NSString *)name forClass:(Class)klass
{
	NSMutableArray *registrations = [_registeredProtocols objectForKey:name];
	if(!registrations) {
		registrations = [NSMutableArray array];
		[_registeredProtocols setObject:registrations forKey:name];
	}
	[registrations addObject:NSStringFromClass(klass)];
}

- (void)registerSingletonInstance:(id)obj forClass:(Class)klass
{
	NSString *klassName = NSStringFromClass(klass);
	@synchronized(klass) {
		[self
		 registerClass:klass
		 forClassName:klassName
		 instantiationMode:IJContextInstantiationModeSingleton
		 instantiationBlock:nil];
		
		id instance = [_registeredClassesSingletonInstances objectForKey:klassName];
		if(instance) {
			[NSException raise:NSInternalInconsistencyException format:@"Class %@ has the instance %@ registered, cannot register %@", klassName, instance, obj];
		}
		[_registeredClassesSingletonInstances setObject:obj forKey:klassName];
	}
}

- (id)instantiateClass:(Class)klass withProperties:(NSDictionary *)props
{
	__block IJClassRegistration *reg = nil;
	__block id instance = nil;
	NSString *klassName = NSStringFromClass(klass);
	
	dispatch_sync(_queue, ^{
		reg = [_registeredClasses objectForKey:klassName];
	});
	
	if(reg) {
		if(reg.mode == IJContextInstantiationModeFactory) {
			instance = [self createClassInstanceFromRegistration:reg withProperties:props];
		} else {
			@synchronized(klass) {
				instance = [_registeredClassesSingletonInstances objectForKey:klassName];
				if(!instance) {
					instance = [self createClassInstanceFromRegistration:reg withProperties:nil];
					[_registeredClassesSingletonInstances setObject:instance forKey:klassName];
				}
			};
		}
	}
	return instance;
}

- (id)instantiateClassImplementingProtocol:(Protocol *)proto withProperties:(NSDictionary *)props
{
	__block NSArray *registrations = nil;
	NSString *pname = NSStringFromProtocol(proto);
	
	dispatch_sync(_queue, ^{
		registrations = [[_registeredProtocols objectForKey:pname] copy];
	});
	
	if([registrations count] == 1) {
		Class klass = NSClassFromString([registrations objectAtIndex:0]);
		return [self instantiateClass:klass withProperties:props];
	} else if([registrations count] == 0) {
		return nil;
	} else {
		[NSException raise:NSInternalInconsistencyException format:@"Protocol %@ has several registered implementations in: %@", pname, registrations];
		return nil;
	}
}

- (NSArray *)instantiateAllClassesImplementingProtocol:(Protocol *)proto withProperties:(NSDictionary *)props
{
	__block NSArray *registrations = nil;
	NSString *pname = NSStringFromProtocol(proto);
	
	dispatch_sync(_queue, ^{
		registrations = [[_registeredProtocols objectForKey:pname] copy];
	});
	
	if([registrations count] > 0) {
		NSMutableArray *allInst = [NSMutableArray arrayWithCapacity:[registrations count]];
		for(NSString *klassName in registrations) {
			Class klass = NSClassFromString(klassName);
			id inst = [self instantiateClass:klass withProperties:props];
			[allInst addObject:inst];
		}
		return [[allInst copy] autorelease];
	} else {
		return nil;
	}
}

#pragma mark -
- (void)bindRegisteredPropertiesWithRegistration:(IJClassRegistration *)reg toInstance:(id)instance
{
	Class klass = reg.klass;
	if([klass respondsToSelector:@selector(injective_requiredProperties)]) {
		__block NSDictionary *registeredProperties;
		
		// check if there is known property-class map and generate one if required
		dispatch_sync(_queue, ^{
			registeredProperties = reg.registeredProperties;
			if(!registeredProperties) {
				reg.registeredProperties = [self createPropertiesMapForClass:klass];
				registeredProperties = reg.registeredProperties;
			}
		});
		
		// iterate over the properties and set up connections via KVC
		// TODO: this can cause deadlocks, that we must fix
		// TODO: check for assign/weak properties? Look for [C]opy, [&]retain or W[eak]
		[registeredProperties enumerateKeysAndObjectsUsingBlock:^(NSString *propName, NSString *propKlassName, BOOL *stop) {
			Class propKlass = objc_getClass([propKlassName cStringUsingEncoding:NSASCIIStringEncoding]);
			if(!propKlass) {
				[NSException raise:NSInternalInconsistencyException format:@"Class %@ is not registered in the runtime, but is required for %@.%@", propKlassName,
				 NSStringFromClass(klass), propName];
			} else {
				[propKlass class];
			}
			id propInstance = [self instantiateClass:propKlass withProperties:nil];
			if(!propInstance) {
				[NSException raise:NSInternalInconsistencyException format:@"Injector %@ doesn't know how to instantiate %@", self, propKlassName];
			}
			[instance setValue:propInstance forKey:propName];
		}];
		
#if 0
#error FIXME we mapped all registeredProperties, need to check only for props, requires additional validation?
		NSMutableSet *registeredPropsSet = [NSMutableSet setWithArray:[registeredProperties allKeys]];
		[registeredPropsSet addObjectsFromArray:[props allKeys]];
		NSMutableSet *requiredPropsSet = [NSMutableSet setWithSet:[klass injective_requiredProperties]];
		[requiredPropsSet minusSet:registeredPropsSet];
		BOOL hasMissingProperties = [requiredPropsSet count] > 0;
		if(hasMissingProperties) {
			[NSException raise:NSInternalInconsistencyException format:@"Class %@ instantiated with %@, but a set of %@ was requested.", NSStringFromClass(klass),
			 [klass injective_requiredProperties], registeredPropsSet];
		}
#endif
	}
}

- (id)createClassInstanceFromRegistration:(IJClassRegistration *)reg withProperties:(NSDictionary *)props
{
	id instance;
	if(reg.block) {
		instance = reg.block(props);
	} else {
		instance = [[[reg.klass alloc] init] autorelease];
	}
	
	[self bindRegisteredPropertiesWithRegistration:reg toInstance:instance];
	[instance setValuesForKeysWithDictionary:props];
	
	return instance;
}

- (NSDictionary *)createPropertiesMapForClass:(Class)klass
{
	NSMutableDictionary *propsDict = [NSMutableDictionary dictionary];
	NSSet *requiredProperties = [self gatherPropertiesForKlass:klass];
	
	for(NSString *propName in requiredProperties) {
		objc_property_t property = class_getProperty(klass, [propName cStringUsingEncoding:NSASCIIStringEncoding]);
		if(property == nil) {
			[NSException raise:NSInternalInconsistencyException format:@"Cannot map required property '%@' of class %@ as there's no such property",
			 propName, NSStringFromClass(klass)];
		}
		const char *cPropAttrib = property_getAttributes(property);
		// the attributes string is always at least 2 chars long, and the 2nd char must be @ for us to proceed
		if(cPropAttrib[1] != '@') {
			[NSException raise:NSInternalInconsistencyException format:@"Cannot map required property '%@' of class %@ as it does not "
			 @"point to object. Attributes: '%s'", propName, NSStringFromClass(klass), cPropAttrib];
		}
		// the attributes string must be at least 5 chars long: T@"<one char here>"
		if(strlen(cPropAttrib) < 5) {
			[NSException raise:NSInternalInconsistencyException format:@"Cannot map required property '%@' of class %@ as it does not "
			 @"contain enough chars to parse class name. Attributes: '%s'", propName, NSStringFromClass(klass), cPropAttrib];
		}
		cPropAttrib = cPropAttrib + 3;
		// we don't support protocols yet
		if(cPropAttrib[0] == '<') {
			[NSException raise:NSInternalInconsistencyException format:@"Cannot map required property '%@' of class %@ as it "
			 @"maps to a Protocol, and we don't support them yet. Attributes: '%s'", propName, NSStringFromClass(klass), cPropAttrib];
		}
		char *cMappedKlassName = strdup(cPropAttrib);
		char *cMappedKlassNameEnd = strchr(cMappedKlassName, '"');
		if(cMappedKlassNameEnd == NULL) {
			[NSException raise:NSInternalInconsistencyException format:@"Cannot map required property '%@' of class %@ as it does not "
			 @"contain the ending '\"'. Attributes: '%s'", propName, NSStringFromClass(klass), cPropAttrib];
		}
		*cMappedKlassNameEnd = '\0';
		NSString *mappedKlassName = [NSString stringWithCString:cMappedKlassName encoding:NSASCIIStringEncoding];
		free(cMappedKlassName);
		
		[propsDict setObject:mappedKlassName forKey:propName];
	}
	
	return [[propsDict copy] autorelease];
}

- (NSSet *)gatherPropertiesForKlass:(Class)klass
{
	NSMutableSet *ms = [NSMutableSet setWithSet:[klass injective_requiredProperties]];
	Class superKlass = class_getSuperclass(klass);
	if([superKlass respondsToSelector:@selector(injective_requiredProperties)]) {
		[ms unionSet:[self gatherPropertiesForKlass:superKlass]];
	}
	return ms;
}

@end

#pragma mark - Injective
@implementation NSObject (Injective)

+ (id)injectiveInstantiateWithProperties:(id)firstValue, ...
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	NSString *key;
	va_list args;
	va_start(args, firstValue);
	
	id value = firstValue;
	
	while(value) {
		key = va_arg(args, id);
		[d setObject:value forKey:key];
		value = va_arg(args, id);
	};
	va_end(args);
	
	return [[IJContext defaultContext] instantiateClass:self withProperties:d];
}

+ (id)injectiveInstantiateWithPropertiesDictionary:(NSDictionary *)properties
{
	return [[IJContext defaultContext] instantiateClass:self withProperties:properties];
}

+ (id)injectiveInstantiate
{
	return [[IJContext defaultContext] instantiateClass:self withProperties:nil];
}

@end
