// Copyright 1997-2006, 2008, 2010, 2013 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniAppKit/NSWindow-OAExtensions.h>
#import <OmniAppKit/NSView-OAExtensions.h>
#import <OmniAppKit/OAViewPicker.h>

#import "OAConstructionTimeView.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

RCS_ID("$Id$")

@interface NSView (DebuggingSPI)
- (NSString *)_subtreeDescription;
@end

static void (*oldBecomeKeyWindow)(id self, SEL _cmd);
static void (*oldResignKeyWindow)(id self, SEL _cmd);
static void (*oldMakeKeyAndOrderFront)(id self, SEL _cmd, id sender);
static void (*oldDidChangeValueForKey)(id self, SEL _cmd, NSString *key);
static id (*oldSetFrameDisplayAnimateIMP)(id self, SEL _cmd, NSRect newFrame, BOOL shouldDisplay, BOOL shouldAnimate);
static NSWindow *becomingKeyWindow = nil;

@implementation NSWindow (OAExtensions)

+ (void)performPosing;
{
    oldBecomeKeyWindow = (void *)OBReplaceMethodImplementationWithSelector(self, @selector(becomeKeyWindow), @selector(replacement_becomeKeyWindow));
    oldResignKeyWindow = (void *)OBReplaceMethodImplementationWithSelector(self, @selector(resignKeyWindow), @selector(replacement_resignKeyWindow));
    oldMakeKeyAndOrderFront = (void *)OBReplaceMethodImplementationWithSelector(self, @selector(makeKeyAndOrderFront:), @selector(replacement_makeKeyAndOrderFront:));
    oldDidChangeValueForKey = (void *)OBReplaceMethodImplementationWithSelector(self, @selector(didChangeValueForKey:), @selector(replacement_didChangeValueForKey:));
    oldSetFrameDisplayAnimateIMP = (typeof(oldSetFrameDisplayAnimateIMP))OBReplaceMethodImplementationWithSelector(self, @selector(setFrame:display:animate:), @selector(replacement_setFrame:display:animate:));    
}

static NSMutableArray *zOrder;

- (id)_addToZOrderArray;
{
    [zOrder addObject:self];
    return nil;
}

// Note that this will not return miniaturized windows (or any other ordered out window)
+ (NSArray *)windowsInZOrder;
{
    zOrder = [[NSMutableArray alloc] init];
    [NSApp makeWindowsPerform:@selector(_addToZOrderArray) inOrder:YES];
    NSArray *result = zOrder;
    zOrder = nil;
    return [result autorelease];
}

- (NSPoint)frameTopLeftPoint;
{
    NSRect windowFrame;

    windowFrame = [self frame];
    return NSMakePoint(NSMinX(windowFrame), NSMaxY(windowFrame));
}

- (void)_sendWindowDidChangeKeyOrFirstResponder;
{
    NSView *rootView = [self contentView];
    NSView *superview;
    
    while ((superview = [rootView superview]))
           rootView = superview;
    
    [rootView windowDidChangeKeyOrFirstResponder];
}

- (void)replacement_becomeKeyWindow;
{
    oldBecomeKeyWindow(self, _cmd);
    [self _sendWindowDidChangeKeyOrFirstResponder];
}

- (void)replacement_resignKeyWindow;
{
    oldResignKeyWindow(self, _cmd);
    [self _sendWindowDidChangeKeyOrFirstResponder];
}

/*" We occasionally want to draw differently based on whether we are in the key window or not (for example, OAAquaButton).  This method allows us to draw correctly the first time we get drawn, when the window is coming on screen due to -makeKeyAndOrderFront:.  The window is not key at that point, but we would like to draw as if it is so that we don't have to redraw later, wasting time and introducing flicker. "*/

- (void)replacement_makeKeyAndOrderFront:(id)sender;
{
    becomingKeyWindow = self;
    oldMakeKeyAndOrderFront(self, _cmd, sender);
    becomingKeyWindow = nil;
}

- (void)replacement_didChangeValueForKey:(NSString *)key;
{
    oldDidChangeValueForKey(self, _cmd, key);
    
    if ([key isEqualToString:@"firstResponder"])
        [self _sendWindowDidChangeKeyOrFirstResponder];
}

/*" There is an elusive crasher (at least in 10.2.x) related to animated frame changes that we believe happens only when the new and old frames are very close in position and size. This method disables the animation if the frame change is below a certain threshold, in an attempt to work around the crasher. "*/
- (void)replacement_setFrame:(NSRect)newFrame display:(BOOL)shouldDisplay animate:(BOOL)shouldAnimate;
{
    NSRect currentFrame = [self frame];

    // Calling this with equal rects prevents any display from actually happening.
    if (NSEqualRects(currentFrame, newFrame))
        return;

    // Don't bother animating if we're not visible
    if (shouldAnimate && ![self isVisible])
        shouldAnimate = NO;

#ifdef OMNI_ASSERTIONS_ON
    // The AppKit method is synchronous, but it can cause timers, etc, to happen that may cause other app code to try to start animating another window (or even the SAME one).  This leads to crashes when AppKit cleans up its animation timer.
    static NSMutableSet *animatingWindows = nil;
    if (!animatingWindows)
        animatingWindows = OFCreateNonOwnedPointerSet();
    OBASSERT([animatingWindows member:self] == nil);
    [animatingWindows addObject:self];
#endif
    
    oldSetFrameDisplayAnimateIMP(self, _cmd, newFrame, shouldDisplay, shouldAnimate);

#ifdef OMNI_ASSERTIONS_ON
    OBASSERT([animatingWindows member:self] == self);
    [animatingWindows removeObject:self];
#endif
}

- (BOOL)isBecomingKey;
{
    return self == becomingKeyWindow;
}

- (BOOL)shouldDrawAsKey;
{
    return [self isKeyWindow];
}

- (void)addConstructionWarning;
{
    // This is hacky, but you should only be calling this in alpha/beta builds of an app anyway.
    NSView *borderView = [self valueForKey:@"borderView"];
    
    NSRect borderBounds = [borderView bounds];
    const CGFloat constructionHeight = 21.0f;
    NSRect contructionFrame = NSMakeRect(NSMinX(borderBounds), NSMaxY(borderBounds) - constructionHeight, NSWidth(borderBounds), constructionHeight);
    OAConstructionTimeView *contructionView = [[OAConstructionTimeView alloc] initWithFrame:contructionFrame];
    [contructionView setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
    [borderView addSubview:contructionView positioned:NSWindowBelow relativeTo:nil];
    [contructionView release];
}

/*" Convert a point from a window's base coordinate system to the CoreGraphics global ("screen") coordinate system. "*/
- (CGPoint)convertBaseToCGScreen:(NSPoint)windowPoint;
{
    // This isn't documented anywhere (sigh...), but it's borne out by experimentation and by a posting to quartz-dev by Mike Paquette.
    // Cocoa and CG both use a single global coordinate system for "screen coordinates" (even in a multi-monitor setup), but they use slightly different ones.
    // Cocoa uses a coordinate system whose origin is at the lower-left of the "origin" or "zero" screen, with Y values increasing upwards; CG has its coordinate system at the upper-left of the "origin" screen, with +Y downwards.
    // The screen in question here is the screen containing the origin, which is not necessarily the same as +[NSScreen mainScreen] (documented to be the screen containing the key window). However, the CG main display (CGMainDisplayID()) is documented to be a display at the origin.
    // Coordinates continue across other screens according to how the screens are arranged logically.

    // We assume here that both Quartz and CG have the same idea about the height (Y-extent) of the main screen; we should check whether this holds in 10.5 with resolution-independent UI.
    
    NSPoint cocoaScreenCoordinates = [self convertBaseToScreen:windowPoint];
    CGRect mainScreenSize = CGDisplayBounds(CGMainDisplayID());
    
    // It's the main screen, so we expect its origin to be at the global origin. If that's not true, our conversion will presumably fail...
    OBASSERT(mainScreenSize.origin.x == 0);
    OBASSERT(mainScreenSize.origin.y == 0);
    
    return CGPointMake(cocoaScreenCoordinates.x,
                       ( mainScreenSize.size.height - cocoaScreenCoordinates.y ));
}

- (void)_visualizeConstraintsMenuAction:(id)sender;
{
    NSMenuItem *item = (NSMenuItem *)sender;
    NSView *view = [item representedObject];
    NSLayoutConstraintOrientation orientation = [item tag];
    [self visualizeConstraints:[view constraintsAffectingLayoutForOrientation:orientation]];
}

- (void)_logSubtreeDescriptionMenuAction:(id)sender;
{
    NSView *view = [sender representedObject];
    if ([view respondsToSelector:@selector(_subtreeDescription)])
        NSLog(@"%@", [[sender representedObject] _subtreeDescription]);
    else
        OBASSERT_NOT_REACHED("Object %@ does not respond to -_subtreeDescription; either the debugging method is gone or it is not an NSView", view);
}

- (void)_copyAddressMenuAction:(id)sender;
{
    NSString *addressString = [NSString stringWithFormat:@"%p", [sender representedObject]];
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];
    [pboard clearContents];
    [pboard writeObjects:[NSArray arrayWithObject:addressString]];
}

- (void)visualizeConstraintsForPickedView:(id)sender;
{
    [OAViewPicker beginPickingForWindow:self withCompletionHandler:^(NSView *pickedView) {
        if (!pickedView)
            return NO;
        
        static NSMenu *constraintsOptions;
        static NSMenuItem *headerItem, *horizontalItem, *verticalItem, *logSubtreeItem, *copyAddressItem;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            constraintsOptions = [[NSMenu alloc] initWithTitle:@"Visualize Constraints"];
            [constraintsOptions setAutoenablesItems:NO];
            
            headerItem = [constraintsOptions addItemWithTitle:@"<PICKED VIEW>" action:@selector(noop:) keyEquivalent:@""];
            [headerItem setEnabled:NO];
            
            horizontalItem = [constraintsOptions addItemWithTitle:@"Visualize horizontal constraints" action:@selector(_visualizeConstraintsMenuAction:) keyEquivalent:@""];
            [horizontalItem setTag:NSLayoutConstraintOrientationHorizontal];
            [horizontalItem setEnabled:YES];
            
            verticalItem = [constraintsOptions addItemWithTitle:@"Visualize vertical constraints" action:@selector(_visualizeConstraintsMenuAction:) keyEquivalent:@""];
            [verticalItem setTag:NSLayoutConstraintOrientationVertical];
            [verticalItem setEnabled:YES];
            
            logSubtreeItem = [constraintsOptions addItemWithTitle:@"Log subview hierarchy" action:@selector(_logSubtreeDescriptionMenuAction:) keyEquivalent:@""];
            [logSubtreeItem setEnabled:YES];
            
            copyAddressItem = [constraintsOptions addItemWithTitle:@"Copy address" action:@selector(_copyAddressMenuAction:) keyEquivalent:@""];
            [copyAddressItem setEnabled:YES];
        });
        
        [headerItem setTitle:[NSString stringWithFormat:@"%@", [pickedView shortDescription]]];
        
        for (NSMenuItem *item in constraintsOptions.itemArray) {
            item.representedObject = pickedView;
            item.target = self;
        }

        BOOL picked = [constraintsOptions popUpMenuPositioningItem:headerItem atLocation:[NSEvent mouseLocation] inView:nil];
        
        [horizontalItem setRepresentedObject:nil];
        [verticalItem setRepresentedObject:nil];
        
        return picked;
    }];
}

// NSCopying protocol

- (id)copyWithZone:(NSZone *)zone;
{
    return [self retain];
}

@end
