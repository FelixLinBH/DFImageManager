<p align="center"><img src="https://cloud.githubusercontent.com/assets/1567433/9706439/4d3fd63c-54ed-11e5-91ec-a52c768b67fe.png" width="70%"/>

Advanced framework for loading, caching, processing, displaying and preheating images. It uses latest advancements in iOS SDK and doesn't reinvent existing technologies.

DFImageManager is a [pipeline](#h_design) that loads images using multiple dependencies which can be injected in runtime. It features [multiple subspecs](#install_using_cocopods) that integrate things like [FLAnimatedImage](https://github.com/Flipboard/FLAnimatedImage), [libwebp](https://developers.google.com/speed/webp/docs/api), and more.

> Programming in Swift? Try [Nuke](https://github.com/kean/Nuke).

1. [Getting Started](#h_getting_started)
2. [Usage](#h_usage)
3. [Design](#h_design)
4. [Installation](#install_using_cocopods)
5. [Requirements](#h_requirements)
6. [Supported Image Formats](#h_supported_image_formats)
7. [Contribution](#h_contribution)

## <a name="h_features"></a>Features

- Zero config
- Works great with both Objective-C and Swift
- Performant, asynchronous, thread safe
- Comprehensive unit test coverage

##### Loading
- Uses [NSURLSession](https://developer.apple.com/library/ios/documentation/Foundation/Reference/NSURLSession_class/) with [HTTP/2](https://en.wikipedia.org/wiki/HTTP/2) support
- Has optional [AFNetworking integration](#install_using_cocopods), combine the power of both frameworks!
- Uses a single fetch operation for multiple equivalent requests
- [Intelligent preheating](https://github.com/kean/DFImageManager/wiki/Image-Preheating-Guide) of images close to the viewport

##### Caching
- Doesn't reinvent caching, relies on [HTTP cache](https://tools.ietf.org/html/rfc7234) and its implementation in [Foundation](https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/URLLoadingSystem/URLLoadingSystem.html)
- Caching is completely transparent to the client
- Two cache layers, including [top level memory cache](https://github.com/kean/DFImageManager/wiki/Image-Caching-Guide) for decompressed images

##### Decoding and Processing
- Animated GIF support using best-in-class [FLAnimatedImage](https://github.com/Flipboard/FLAnimatedImage) library
- [WebP](https://developers.google.com/speed/webp/) support
- Progressive image decoding (including progressive JPEG)
- Background image decompression and scaling in a single step
- Resize and crop loaded images to [fit displayed size](https://developer.apple.com/library/ios/qa/qa1708/_index.html), add rounded corners or circle

##### Advanced
- Customize different parts of the framework using dependency injection
- Create custom image managers
- [Compose image managers](https://github.com/kean/DFImageManager/wiki/Extending-Image-Manager-Guide#using-dfcompositeimagemanager) into a tree of responsibility

## <a name="h_getting_started"></a>Getting Started
- Take a look at comprehensive [demo](https://github.com/kean/DFImageManager/tree/master/Demo), it's easy to install with `pod try DFImageManager` command
- Check out complete [documentation](http://cocoadocs.org/docsets/DFImageManager) and [Wiki](https://github.com/kean/DFImageManager/wiki)
- [Install using CocoaPods](#install_using_cocopods), import `<DFImageManager/DFImageManagerKit.h>` and enjoy!

## <a name="h_usage"></a>Usage

#### Zero Config

```objective-c
[[DFImageManager imageTaskForResource:[NSURL URLWithString:@"http://..."] completion:^(UIImage *image, NSError *error, DFImageResponse *response, DFImageTask *task){
    // Use loaded image
}] resume];
```

#### Adding Request Options

```objective-c
NSURL *imageURL = [NSURL URLWithString:@"http://..."];

DFMutableImageRequestOptions *options = [DFMutableImageRequestOptions new]; // builder
options.priority = DFImageRequestPriorityHigh;
options.allowsClipping = YES;

DFImageRequest *request = [DFImageRequest requestWithResource:imageURL targetSize:CGSizeMake(100.f, 100.f) contentMode:DFImageContentModeAspectFill options:options.options];

[[DFImageManager imageTaskForRequest:request completion:^(UIImage *image, NSError *error, DFImageResponse *response, DFImageTask *imageTask) {
    // Image is resized and clipped to fill 100x100px square
    if (response.isFastResponse) {
        // Image was returned synchronously from the memory cache
    }
}] resume];
```

#### Using Image Task

```objective-c
DFImageTask *task = [DFImageManager imageTaskForResource:[NSURL URLWithString:@"http://..."] completion:nil];
[task resume];

NSProgress *progress = task.progress; // Track progress
task.priority = DFImageRequestPriorityHigh; // Change priority of executing task
[task cancel]; // Cancel image task
```

#### Using UI Components
Use methods from `UIImageView` category for simple cases:
```objective-c
UIImageView *imageView = ...;
[imageView df_setImageWithResource:[NSURL URLWithString:@"http://..."]];
```

Use `DFImageView` for more advanced features:
```objective-c
DFImageView *imageView = ...;
imageView.allowsAnimations = YES; // Animates images when the response isn't fast enough
imageView.managesRequestPriorities = YES; // Automatically changes current request priority when image view gets added/removed from the window

[imageView prepareForReuse];
[imageView setImageWithResource:[NSURL URLWithString:@"http://..."]];
```

#### UICollectionView

```objective-c
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = <#cell#>
    DFImageView *imageView = (id)[cell viewWithTag:15];
    if (!imageView) {
        imageView = [[DFImageView alloc] initWithFrame:cell.bounds];
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.tag = 15;
        [cell addSubview:imageView];
    }
    [imageView prepareForReuse];
    [imageView setImageWithResource:<#image_url#>];
    return cell;
}
```

Cancel image task as soon as the cell goes offscreen (optional):

```objective-c
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    DFImageView *imageView = (id)[cell viewWithTag:15];
    [imageView prepareForReuse];
}
```

#### Preheating Images

```objective-c
NSArray *requestsForAddedItems = ...; // Create image requests
[DFImageManager startPreheatingImagesForRequests:requestsForAddedItems];

NSArray *requestsForRemovedItems = ...; // Create image requests
[DFImageManager stopPreheatingImagesForRequests:requestsForRemovedItems];
```

#### Requesting Image for PHAsset

```objective-c
PHAsset *asset = ...;
DFImageRequest *request = [DFImageRequest requestWithResource:asset targetSize:CGSizeMake(100.f, 100.f) contentMode:DFImageContentModeAspectFill options:nil];
[[DFImageManager imageTaskForRequest:request completion:^(UIImage *image, NSDictionary *info) {
    // Image resized to 100x100px square
}] resume];
```

#### Progressive Image Decoding

```objective-c
// Enable progressive image decoding
[DFImageManagerConfiguration setAllowsProgressiveImage:YES];

// Create image request that allows progressive image
DFMutableImageRequestOptions *options = [DFMutableImageRequestOptions new];
options.allowsProgressiveImage = YES;
DFImageRequest *request = // Create request with given options

DFImageTask *task = .../ Create image task
task.progressiveImageHandler = ^(UIImage *__nonnull image){
    imageView.image = image;
};
[task resume];
```

#### Creating Image Managers
You can either create `DFImageManager` instance with a custom configuration or even provide your own implementation of `DFImageManaging` protocol.
```objective-c
// Create dependencies. You can either use existing classes or provide your own.
id<DFImageFetching> fetcher = ...; // Create image fetcher
id<DFImageDecoding> decoder = ...; // Create image decoder
id<DFImageProcessing> processor = ...; // Create image processor
id<DFImageCaching> cache = ...; // Create image cache

DFImageManagerConfiguration *configuration = [[DFImageManagerConfiguration alloc] initWithFetcher:fetcher];
configuration.decoder = decoder;
configuration.processor = processor;
configuration.cache = cache;

[DFImageManager setSharedManager:[[DFImageManager alloc] initWithConfiguration:configuration]];
```

#### Composing Image Managers
The `DFCompositeImageManager` allows clients to construct a tree of responsibility from multiple image managers, requests are dynamically dispatched between them. Each manager should conform to `DFImageManaging` protocol. The `DFCompositeImageManager` also conforms to `DFImageManaging` protocol, which lets clients treat individual objects and compositions uniformly. For more info see [Composing Image Managers](https://github.com/kean/DFImageManager/wiki/Extending-Image-Manager-Guide#using-dfcompositeimagemanager).

```objective-c
id<DFImageManaging> manager = <#manager#>

// Create composite manager with your custom manager and all built-in managers.
NSArray *managers = @[ manager, [DFImageManager sharedManager] ];
id<DFImageManaging> compositeImageManager = [[DFCompositeImageManager alloc] initWithImageManagers:managers];

// Use dependency injector to set shared manager
[DFImageManager setSharedManager:compositeImageManager];
```

## <a name="h_design"></a>Design

<img src="https://cloud.githubusercontent.com/assets/1567433/9706417/0352d3bc-54ed-11e5-94ff-cb8691800f78.png" width="66%"/>

|Protocol|Description|
|--------|-----------|
|`DFImageManaging`|A high-level API for loading images|
|`DFImageFetching`|Performs fetching of image data (`NSData`)|
|`DFImageDecoding`|Converts `NSData` to `UIImage` objects|
|`DFImageProcessing`|Processes decoded images|
|`DFImageCaching`|Stores processed images into memory cache|

## <a name="install_using_cocopods"></a>Installation with [CocoaPods](http://cocoapods.org)

To install DFImageManager add a dependency in your Podfile:
```ruby
# Podfile
# platform :ios, '7.0'
# platform :watchos, '2.0'
pod 'DFImageManager'
```

By default it will install these subspecs (if they are available for your platform):
- `DFImageManager/Core` - DFImageManager core classes
- `DFImageManager/UI` - UI components
- `DFImageManager/NSURLSession` - basic networking on top of NSURLSession
- `DFImageManager/PhotosKit` - Photos Framework support

There are three more optional subspecs:
- `DFImageManager/AFNetworking` - replaces networking stack with [AFNetworking](https://github.com/AFNetworking/AFNetworking)
- `DFImageManager/GIF` - GIF support with a [FLAnimatedImage](https://github.com/Flipboard/FLAnimatedImage) dependency
- `DFImageManager/WebP` - WebP support with a [libwebp](https://cocoapods.org/pods/libwebp) dependency

To install optional subspecs include them in your Podfile:
```ruby
# Podfile
pod 'DFImageManager'
pod 'DFImageManager/AFNetworking'
pod 'DFImageManager/GIF'
pod 'DFImageManager/WebP'
```

## <a name="h_requirements"></a>Requirements
- iOS 7.0+ / watchOS 2
- Xcode 6.0+

## <a name="h_supported_image_formats"></a>Supported Image Formats
- Image formats supported by `UIImage` (JPEG, PNG, BMP, [and more](https://developer.apple.com/library/ios/documentation/UIKit/Reference/UIImage_Class/))
- GIF (`GIF` subspec)
- WebP (`WebP` subspec)

## <a name="h_contribution"></a>Contribution

- If you **need help**, use [Stack Overflow](http://stackoverflow.com/questions/tagged/dfimagemanager). (Tag 'dfimagemanager')
- If you **found a bug**, and can provide steps to reproduce it, open an issue.
- If you **have a feature request**, open an issue.
- If you **want to contribute**, branch of the `develop` branch and submit a pull request.

## Contacts

<a href="https://github.com/kean">
<img src="https://cloud.githubusercontent.com/assets/1567433/6521218/9c7e2502-c378-11e4-9431-c7255cf39577.png" height="44" hspace="2"/>
</a>
<a href="https://twitter.com/a_grebenyuk">
<img src="https://cloud.githubusercontent.com/assets/1567433/6521243/fb085da4-c378-11e4-973e-1eeeac4b5ba5.png" height="44" hspace="2"/>
</a>
<a href="https://www.linkedin.com/pub/alexander-grebenyuk/83/b43/3a0">
<img src="https://cloud.githubusercontent.com/assets/1567433/6521256/20247bc2-c379-11e4-8e9e-417123debb8c.png" height="44" hspace="2"/>
</a>

## License

DFImageManager is available under the MIT license. See the LICENSE file for more info.
