/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXVideoHandler.h"
#import "BXEmulatorPrivate.h"
#import "BXVideoFrame.h"
#import "BXGeometry.h"
#import "BXFilterDefinitions.h"

#import "render.h"
#import "vga.h"


#pragma mark -
#pragma mark Really genuinely private functions

@interface BXVideoHandler ()

- (const BXFilterDefinition *) _paramsForFilterType: (BXFilterType)filterType;

- (BOOL) _shouldApplyFilterType: (BXFilterType)type
				 fromResolution: (NSSize)resolution
					 toViewport: (NSSize)viewportSize 
					 isTextMode: (BOOL)isTextMode;

- (NSInteger) _filterScaleForType: (BXFilterType)type
				   fromResolution: (NSSize)resolution
					   toViewport: (NSSize)viewportSize
					   isTextMode: (BOOL)isTextMode;

- (NSInteger) _maxFilterScaleForResolution: (NSSize)resolution;

- (void) _applyAspectCorrectionToFrame: (BXVideoFrame *)frame;

@end


@implementation BXVideoHandler
@synthesize currentFrame = _currentFrame;
@synthesize emulator = _emulator;
@synthesize aspectCorrected = _aspectCorrected;
@synthesize filterType = _filterType;


- (id) init
{
	if ((self = [super init]))
	{
		_currentVideoMode = M_TEXT;
	}
	return self;
}

- (void) dealloc
{	
    self.currentFrame = nil;
	[super dealloc];
}

- (NSSize) resolution
{
	NSSize size = NSZeroSize;
	if (self.emulator.isExecuting)
	{
		size.width	= (CGFloat)render.src.width;
		size.height	= (CGFloat)render.src.height;
	}
	return size;
}

//Returns whether the emulator is currently rendering in a text-only graphics mode.
- (BOOL) isInTextMode
{
	BOOL textMode = NO;
	if (self.emulator.isExecuting)
	{
		switch (_currentVideoMode)
		{
			case M_TEXT:
            case M_TANDY_TEXT:
            case M_HERC_TEXT:
                textMode = YES;
		}
	}
	return textMode;
}

- (NSUInteger) frameskip
{
	return (NSUInteger)render.frameskip.max;
}

- (void) setFrameskip: (NSUInteger)frameskip
{
	render.frameskip.max = (Bitu)frameskip;
}

//Toggles aspect ratio correction and resets the renderer to apply the change immediately.
- (void) setAspectCorrected: (BOOL)correct
{
	if (correct != self.isAspectCorrected)
	{
		_aspectCorrected = correct;
		//Reset to force a new frame buffer at the corrected size
		//TODO: this would be unnecessary if we applied aspect correction higher up
		//at the windowing level
		[self reset];
	}
}

//Chooses the specified filter, and resets the renderer to apply the change immediately.
- (void) setFilterType: (BXFilterType)type
{
	if (type != _filterType)
	{
		NSAssert1(type <= sizeof(BXFilters), @"Invalid filter type provided to setFilterType: %i", type);
				
		_filterType = type;
		[self reset];
	}
}

//Returns whether the chosen filter is actually being rendered.
- (BOOL) filterIsActive
{
	BOOL isActive = NO;
	if (self.emulator.isExecuting)
	{
		isActive = (self.filterType == (NSUInteger)render.scale.op);
	}
	return isActive;
}

//Reinitialises DOSBox's graphical subsystem and redraws the render region.
//This is called after resizing the session window or toggling rendering options.
- (void) reset
{
	if (self.emulator.isExecuting)
	{
        if (self.emulator.emulationThread != [NSThread currentThread])
        {
            [self performSelector: _cmd
                         onThread: self.emulator.emulationThread
                       withObject: nil
                    waitUntilDone: NO];
        }
        else
        {
            if (_frameInProgress) [self finishFrameWithChanges: NULL];
            
            if (_callback) _callback(GFX_CallBackReset);
            //CPU_Reset_AutoAdjust();
        }
	}
}

- (void) shutdown
{
	[self finishFrameWithChanges: 0];
	if (_callback) _callback(GFX_CallBackStop);
}


#pragma mark -
#pragma mark DOSBox callbacks

- (void) _applyAspectCorrectionToFrame: (BXVideoFrame *)frame
{
	//If aspect correction is turned on and we're in a graphical game,
	//then apply the correction. (For now we leave it off for text-modes
	//since they tend to look crappy scaled at small window sizes.)
	if (self.isAspectCorrected && !self.isInTextMode)
	{
		[frame useAspectRatio: BX4by3AspectRatio];
	}
	else [frame useSquarePixels];
}

- (void) prepareForOutputSize: (NSSize)outputSize
                      atScale: (NSSize)scale
                 withCallback: (GFX_CallBack_t)newCallback
{
	//Synchronise our record of the current video mode with the new video mode
	BOOL wasTextMode = self.isInTextMode;
	if (_currentVideoMode != vga.mode)
	{
		[self willChangeValueForKey: @"isInTextMode"];
		_currentVideoMode = vga.mode;
		[self didChangeValueForKey: @"isInTextMode"];
	}
	BOOL nowTextMode = self.isInTextMode;
	
	//If we were in the middle of a frame then cancel it
	_frameInProgress = NO;
	
	_callback = newCallback;
	
	//Check if we can reuse our existing framebuffer: if not, create a new one
	if (!NSEqualSizes(outputSize, self.currentFrame.size))
	{
        self.currentFrame = [BXVideoFrame frameWithSize: outputSize depth: 4];
	}
	
    self.currentFrame.baseResolution = self.resolution;
	[self _applyAspectCorrectionToFrame: self.currentFrame];
	
	
	//Send notifications if the display mode has changed
	
	if (wasTextMode && !nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidBeginGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidBeginGraphicalContext:)
                                    userInfo: nil];
	
	else if (!wasTextMode && nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidFinishGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidFinishGraphicalContext:)
                                    userInfo: nil];
}

- (BOOL) startFrameWithBuffer: (void **)buffer pitch: (NSUInteger *)pitch
{
	if (_frameInProgress) 
	{
		NSLog(@"Tried to start a new frame while one was still in progress!");
		return NO;
	}
	
	if (!self.currentFrame)
	{
		NSLog(@"Tried to start a frame before any framebuffer was created!");
		return NO;
	}
	
	*buffer	= self.currentFrame.mutableBytes;
    *pitch	= self.currentFrame.pitch;
    
    [self.currentFrame clearDirtyRegions];
	
	_frameInProgress = YES;
	return YES;
}

- (void) finishFrameWithChanges: (const uint16_t *)dirtyBlocks
{
	if (self.currentFrame && dirtyBlocks)
	{
        //Convert DOSBox's array of dirty blocks into a set of ranges
        NSUInteger i=0, currentOffset = 0, maxOffset = self.currentFrame.size.height;
        while (currentOffset < maxOffset)
        {
            NSUInteger regionLength = dirtyBlocks[i];
            
            //Odd-numbered indices represent blocks of lines that are dirty;
            //Even-numbered indices represent clean regions that should be skipped.
            BOOL isDirtyBlock = (i % 2 != 0);
            
            if (isDirtyBlock)
            {
                [self.currentFrame setNeedsDisplayInRegion: NSMakeRange(currentOffset, regionLength)];
            }
            
            currentOffset += regionLength;
            i++;
        }
        
        [self.emulator _didFinishFrame: self.currentFrame];
	}
	_frameInProgress = NO;
}

- (NSUInteger) paletteEntryWithRed: (NSUInteger)red
							 green: (NSUInteger)green
							  blue: (NSUInteger)blue;
{
	//Copypasta straight from sdlmain.cpp.
	return ((blue << 0) | (green << 8) | (red << 16)) | (255 << 24);
}


#pragma mark -
#pragma mark Rendering strategy

- (void) applyRenderingStrategy
{
	//Work out how much we will need to scale the resolution to fit the viewport
	NSSize resolution			= self.resolution;	
	NSSize viewportSize			= [self.emulator.delegate viewportSizeForEmulator: self.emulator];
	
	BOOL isTextMode				= self.isInTextMode;
	NSInteger maxFilterScale	= [self _maxFilterScaleForResolution: resolution];	
	
	
	//Start off with a passthrough filter as the default
	BXFilterType activeType		= BXFilterNormal;
	NSInteger filterScale		= 1;
	BXFilterType desiredType	= self.filterType;
	
	//Decide if we can use our selected filter at this scale, and if so at what scale
	if (desiredType != BXFilterNormal &&
		[self _shouldApplyFilterType: desiredType
					  fromResolution: resolution
						  toViewport: viewportSize
						  isTextMode: isTextMode])
	{
		activeType = desiredType;
		//Now decide on what operation size the scaler should use
		filterScale = [self _filterScaleForType: activeType
								 fromResolution: resolution
									 toViewport: viewportSize
									 isTextMode: isTextMode];
	}
	
	//Make sure we don't go over the maximum size imposed by the OpenGL hardware
	filterScale = MIN(filterScale, maxFilterScale);
	
	
	//Finally, apply the values to DOSBox
	render.aspect		= NO; //We apply our own aspect correction separately
	render.scale.forced	= YES;
	render.scale.size	= (Bitu)filterScale;
	render.scale.op		= (scalerOperation_t)activeType;
}

- (const BXFilterDefinition *) _paramsForFilterType: (BXFilterType)type
{
	NSAssert1(type <= sizeof(BXFilters), @"Invalid filter type provided to paramsForFilterType: %i", type);
	
    return BXFilters[type];
}


//Return the appropriate filter size to scale the given resolution up to the specified viewport.
//This is usually the viewport height divided by the resolution height and rounded up, to ensure
//we're always rendering larger than we need so that the graphics are crisper when scaled down.
//However we finesse this for some filters that look like shit when scaled down too much.
//(We base this on height rather than width, so that we'll use the larger filter size for
//aspect-ratio corrected surfaces.)
- (NSInteger) _filterScaleForType: (BXFilterType)type
				   fromResolution: (NSSize)resolution
					   toViewport: (NSSize)viewportSize
					   isTextMode: (BOOL) isTextMode
{
	const BXFilterDefinition *params = [self _paramsForFilterType: type];
	
	NSSize scale = NSMakeSize(viewportSize.width / resolution.width,
							  viewportSize.height / resolution.height);
	
	NSUInteger filterScale = (NSUInteger)ceilf(scale.height - params->outputScaleBias);
	if (filterScale < params->minFilterScale) filterScale = params->minFilterScale;
	if (filterScale > params->maxFilterScale) filterScale = params->maxFilterScale;
	
	return filterScale;
}

//Returns whether our selected filter should be applied for the specified transformation.
- (BOOL) _shouldApplyFilterType: (BXFilterType)type
				 fromResolution: (NSSize)resolution
					 toViewport: (NSSize)viewportSize
					 isTextMode: (BOOL)isTextMode
{
	const BXFilterDefinition *params = [self _paramsForFilterType: type];
	
	//Disable scalers for high-resolution graphics modes
	//(We leave them available for text modes)
	if (!isTextMode && !sizeFitsWithinSize(resolution, params->maxResolution)) return NO;
	
	NSSize scale = NSMakeSize(viewportSize.width / resolution.width,
							  viewportSize.height / resolution.height);
	
	//Scale is too small for filter to be applied
	if (scale.height < params->minOutputScale) return NO;
	
	//If we got this far, go for it!
	return YES;
}

- (NSInteger) _maxFilterScaleForResolution: (NSSize)resolution
{
	NSSize maxFrameSize	= [self.emulator.delegate maxFrameSizeForEmulator: self.emulator];
	//Work out how big a filter operation size we can use, given the maximum output size
	NSInteger maxScale	= floorf(MIN(maxFrameSize.width / resolution.width,
                                     maxFrameSize.height / resolution.height));
	
	return maxScale;
}

@end
