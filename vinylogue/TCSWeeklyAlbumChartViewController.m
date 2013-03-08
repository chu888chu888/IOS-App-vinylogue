//
//  TCSWeeklyAlbumChartViewController.m
//  vinylogue
//
//  Created by Christopher Trott on 2/18/13.
//  Copyright (c) 2013 TwoCentStudios. All rights reserved.
//

#import "TCSWeeklyAlbumChartViewController.h"
#import "TCSUserNameViewController.h"
#import "TCSSettingsViewController.h"

#import <ReactiveCocoa/ReactiveCocoa.h>
#import "EXTScope.h"

#import "TCSLastFMAPIClient.h"
#import "WeeklyAlbumChart.h"
#import "WeeklyChart.h"

#import "TCSSlideSelectView.h"
#import "TCSAlbumArtistPlayCountCell.h"
#import "TCSEmptyErrorView.h"
#import "TCSInnerShadowView.h"

@interface TCSWeeklyAlbumChartViewController ()

// Views
@property (nonatomic, strong) TCSSlideSelectView *slideSelectView;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UIImageView *loadingImageView;

// Datasources
@property (atomic, copy) NSString *userName;
@property (atomic, strong) TCSLastFMAPIClient *lastFMClient;
@property (atomic, strong) NSArray *weeklyCharts; // list of to:from: dates we can request
@property (atomic, strong) NSArray *rawAlbumChartsForWeek; // prefiltered charts
@property (atomic, strong) NSArray *albumChartsForWeek; // filtered charts to display

@property (atomic, strong) NSCalendar *calendar;
@property (atomic, strong) NSDate *now;
@property (atomic, strong) NSDate *displayingDate;
@property (atomic) NSUInteger displayingYearsAgo;
@property (atomic, strong) WeeklyChart *displayingWeeklyChart;
@property (atomic, strong) NSDate *earliestScrobbleDate;
@property (atomic, strong) NSDate *latestScrobbleDate;

// Controller state
@property (atomic) BOOL canMoveForwardOneYear;
@property (atomic) BOOL canMoveBackOneYear;
@property (atomic) BOOL showingError;
@property (atomic) NSString *showingErrorMessage;
@property (atomic) BOOL showingEmpty;
@property (atomic) BOOL showingLoading;

// Preferences
@property (nonatomic) NSUInteger playCountFilter;

@end

@implementation TCSWeeklyAlbumChartViewController

- (id)initWithUserName:(NSString *)userName playCountFilter:(NSUInteger)playCountFilter{
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    self.title = NSLocalizedString(@"charts", nil);
    
    // userName and playCountFilter are initialized on startup and cannot be changed in the controller's lifetime
    self.userName = userName;
    self.playCountFilter = playCountFilter;
    self.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
  }
  return self;
}

- (void)loadView{
  self.view = [[UIView alloc] init];
  self.view.autoresizesSubviews = YES;
  
  // subview attributes are defined in view getters section
  [self.view addSubview:self.slideSelectView];
  
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  [self.view addSubview:self.tableView];
  
  // loading view is shown as bar button item
  UIBarButtonItem *loadingItem = [[UIBarButtonItem alloc] initWithCustomView:self.loadingImageView];
  self.loadingImageView.hidden = YES;
  self.navigationItem.rightBarButtonItem = loadingItem;
  
  // double tap on the slide view to hide the nav bar and status bar
  UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doDoubleTap:)];
  doubleTap.numberOfTapsRequired = 2;
  [self.slideSelectView.frontView addGestureRecognizer:doubleTap];
}

- (void)viewDidLoad{
  [super viewDidLoad];
  
  // two helper methods to set up all the signals that define the controller's behavior
  [self setUpViewSignals];
  [self setUpDataSignals];
  
  // these assignments trigger the controller to begin its actions
  self.now = [NSDate date];
  self.displayingYearsAgo = 1;
}

// Subscribing to all the signals that deal with views and UI
- (void)setUpViewSignals{
  @weakify(self);
  
  // SlideSelectView: Top Label
  // Depends on: userName
  [[RACAbleWithStart(self.userName) deliverOn:[RACScheduler mainThreadScheduler]] subscribeNext:^(NSString *userName) {
    @strongify(self);
    if (userName){
      self.slideSelectView.topLabel.text = [NSString stringWithFormat:@"%@", userName];
      self.showingError = NO;
    }else{
      self.slideSelectView.topLabel.text = @"No last.fm user";
      self.showingErrorMessage = @"No last.fm user!";
      self.showingError = YES;
    }
    [self.slideSelectView setNeedsLayout];
  }];
  
  // SlideSelectView: Bottom Label, Left Label, Right Label
  // Depend on: displayingDate, earliestScrobbleDate, latestScrobbleDate
  [[[RACSignal combineLatest:@[RACAbleWithStart(self.displayingDate), RACAbleWithStart(self.earliestScrobbleDate), RACAbleWithStart(self.latestScrobbleDate)] ] deliverOn:[RACScheduler mainThreadScheduler]]
   subscribeNext:^(RACTuple *dates) {
     NSDate *displayingDate = dates.first;
     NSDate *earliestScrobbleDate = dates.second;
     NSDate *latestScrobbleDate = dates.third;
    @strongify(self);
    if (displayingDate){
      // Set the displaying date
      NSDateComponents *components = [self.calendar components:NSYearForWeekOfYearCalendarUnit|NSYearCalendarUnit|NSWeekOfYearCalendarUnit fromDate:displayingDate];
      self.slideSelectView.bottomLabel.text = [NSString stringWithFormat:@"WEEK %i of %i", components.weekOfYear, components.yearForWeekOfYear];
      
      // Set up date calculation shenanigans
      NSDateComponents *pastComponents = [[NSDateComponents alloc] init];
      pastComponents.year = -1;
      NSDateComponents *futureComponents = [[NSDateComponents alloc] init];
      futureComponents.year = 1;
      NSDate *pastTargetDate = [self.calendar dateByAddingComponents:pastComponents toDate:displayingDate options:0];
      NSDate *futureTargetDate = [self.calendar dateByAddingComponents:futureComponents toDate:displayingDate options:0];
      
      self.canMoveBackOneYear = ([pastTargetDate compare:earliestScrobbleDate] == NSOrderedDescending);
      self.canMoveForwardOneYear = ([futureTargetDate compare:latestScrobbleDate] == NSOrderedAscending);
      
      // Only show the left and right labels/arrows if there's data there to jump to
      if (self.canMoveBackOneYear){
        self.slideSelectView.backLeftLabel.text = [NSString stringWithFormat:@"%i", components.yearForWeekOfYear-1];
        self.slideSelectView.backLeftButton.hidden = NO;
      }else{
        self.slideSelectView.backLeftLabel.text = nil;
        self.slideSelectView.backLeftButton.hidden = YES;
      }
      if (self.canMoveForwardOneYear){
        self.slideSelectView.backRightLabel.text = [NSString stringWithFormat:@"%i", components.yearForWeekOfYear+1];
        self.slideSelectView.backRightButton.hidden = NO;
      }else{
        self.slideSelectView.backRightLabel.text = nil;
        self.slideSelectView.backRightButton.hidden = YES;
      }
      
    }else{
      self.slideSelectView.bottomLabel.text = nil;
      self.slideSelectView.backLeftLabel.text = nil;
      self.slideSelectView.backRightLabel.text = nil;
    }
    
    // Allow scrollview to begin animation before updating label sizes
   [self.slideSelectView performSelector:@selector(setNeedsLayout) withObject:self.slideSelectView afterDelay:0];
  }];
  
  // Show or hide the empty view
  [[[RACAble(self.showingEmpty) distinctUntilChanged] deliverOn:[RACScheduler mainThreadScheduler]]
   subscribeNext:^(NSNumber *showingEmpty) {
    @strongify(self);
    BOOL isShowingEmpty = [showingEmpty boolValue];
    if (isShowingEmpty && !self.showingError){
      NSString *subtitle = [NSString stringWithFormat:@"Looks like %@ didn't listen to much music this week.", self.userName];
      self.emptyView = [TCSEmptyErrorView emptyViewWithTitle:@"No charts!" subtitle:subtitle];
      [self.view addSubview:self.emptyView];
    }else{
      [self.emptyView removeFromSuperview];
      self.emptyView = nil;
    }
  }];
  
  // Show or hide the error view
  [[[RACAble(self.showingError) distinctUntilChanged] deliverOn:[RACScheduler mainThreadScheduler]]
   subscribeNext:^(NSNumber *showingError) {
    @strongify(self);
    BOOL isShowingError = [showingError boolValue];
    if (isShowingError){
      self.showingEmpty = NO; // Don't show empty or loading if there's an error
      self.showingLoading = NO;
      NSString *message = self.showingErrorMessage ? self.showingErrorMessage : @"Undefined error";
      self.errorView = [TCSEmptyErrorView errorViewWithTitle:message actionTitle:nil actionTarget:nil actionSelector:nil];
      [self.view addSubview:self.errorView];
      [self.errorView setNeedsDisplay];
    }else{
      [self.errorView removeFromSuperview];
      self.errorView = nil;
      self.showingErrorMessage = nil;
    }
  }];
  
  // Show or hide the loading view
  [[[RACAble(self.showingLoading) distinctUntilChanged] deliverOn:[RACScheduler mainThreadScheduler]]
   subscribeNext:^(NSNumber *showingLoading) {
    @strongify(self);
    BOOL isShowingLoading = [showingLoading boolValue];
    if (isShowingLoading){
      [self.loadingImageView startAnimating];
      self.loadingImageView.hidden = NO;
    }else{
      [self.loadingImageView stopAnimating];
      self.loadingImageView.hidden = YES;
    }
  }];

  // Dim the tableview when the slide select view is sliding
  [RACAble(self.slideSelectView.scrollView.contentOffset) subscribeNext:^(id offset) {
    @strongify(self);
    CGFloat x = [offset CGPointValue].x;
    self.tableView.alpha = MAX(1 - (fabsf(x)/50.0f), 0.4f);
  }];
}

// All the signals that deal with acquiring and reacting to data changes
- (void)setUpDataSignals{

  @weakify(self);

  // Setting the username triggers loading of the lastFMClient
  [[RACAbleWithStart(self.userName) filter:^BOOL(id x) {
    return (x != nil);
  }] subscribeNext:^(NSString *userName) {
    NSLog(@"Loading client for %@...", userName);
    @strongify(self);
    self.lastFMClient = [TCSLastFMAPIClient clientForUserName:userName];
  }];
    
  // Update the date being displayed based on the current date/time and how many years ago we want to go back
  RAC(self.displayingDate) = [[[[RACSignal combineLatest:@[ RACAble(self.now), RACAble(self.displayingYearsAgo) ]]
                                deliverOn:[RACScheduler scheduler]]
                               map:^(RACTuple *t){
                                 NSDate *now = [t first];
                                 NSNumber *displayingYearsAgo = [t second];
                                 NSLog(@"Calculating time range for %@ year(s) ago...", displayingYearsAgo);
                                 NSDateComponents *components = [[NSDateComponents alloc] init];
                                 components.year = -1*[displayingYearsAgo integerValue];
                                 return [self.calendar dateByAddingComponents:components toDate:now options:0];
                               }] filter:^BOOL(id x) {
                                 NSLog(@"Time range calculated");
                                 return (x != nil);
                               }];
  
  // When the lastFMClient changes (probably because the username changed), look up the weekly chart list
  [[[RACAbleWithStart(self.lastFMClient) filter:^BOOL(id x) {
    return (x != nil);
  }] deliverOn:[RACScheduler scheduler]] subscribeNext:^(id x) {
    NSLog(@"Fetching date ranges for available charts...");
    @strongify(self);
    self.showingLoading = YES;
    [[[self.lastFMClient fetchWeeklyChartList] deliverOn:[RACScheduler scheduler]] subscribeNext:^(NSArray *weeklyCharts) {
      @strongify(self);
      self.weeklyCharts = weeklyCharts;
      if ([weeklyCharts count] > 0){
        WeeklyChart *firstChart = self.weeklyCharts[0];
        WeeklyChart *lastChart = [self.weeklyCharts lastObject];
        self.earliestScrobbleDate = firstChart.from;
        self.latestScrobbleDate = lastChart.to;
      }
      self.showingLoading = NO;
    } error:^(NSError *error) {
      @strongify(self);
      NSLog(@"There was an error fetching the weekly chart list!");
      self.showingErrorMessage = error.localizedDescription;
      self.showingError = YES;
    }];
  }];
  
  // When the weekly charts array changes (probably loading for the first time), or the displaying date changes (probably looking for a previous year), set the new weeklyChart (the exact week range that last.fm expects)
  RAC(self.displayingWeeklyChart) =
  [[[RACSignal combineLatest:@[ RACAble(self.weeklyCharts), RACAble(self.displayingDate)]]
    deliverOn:[RACScheduler scheduler]]
   map:^id(RACTuple *t) {
     NSLog(@"Calculating the date range for the weekly chart...");
     @strongify(self);
     self.showingError = NO;
     self.showingLoading = YES;
     NSArray *weeklyCharts = t.first;
     NSDate *displayingDate = t.second;
     return [[weeklyCharts.rac_sequence
              filter:^BOOL(WeeklyChart *weeklyChart) {
                return (([weeklyChart.from compare:displayingDate] == NSOrderedAscending) && ([weeklyChart.to compare:displayingDate] == NSOrderedDescending));
              }] head];
   }];
  
  // When the weeklychart changes (being loaded the first time, or the display date changed), fetch the list of albums for that time period
  [[[RACAble(self.displayingWeeklyChart) filter:^BOOL(id x) {
    return (x != nil);
  }] deliverOn:[RACScheduler scheduler]]
   subscribeNext:^(WeeklyChart *displayingWeeklyChart) {
     NSLog(@"Loading album charts for the selected week...");
     @strongify(self);
     [[[self.lastFMClient fetchWeeklyAlbumChartForChart:displayingWeeklyChart]
       deliverOn:[RACScheduler scheduler]]
      subscribeNext:^(NSArray *albumChartsForWeek) {
        NSLog(@"Copying raw weekly charts...");
        @strongify(self);
        self.rawAlbumChartsForWeek = albumChartsForWeek;
      } error:^(NSError *error) {
        @strongify(self);
        self.albumChartsForWeek = nil;
        NSLog(@"There was an error fetching the weekly album charts!");
        self.showingErrorMessage = error.localizedDescription;
        self.showingError = YES;
      }];
   }];
  
  // Filter the raw album charts returned by the server based on user's play count filter
  // Run whenever the raw albums change or the play count filter changes (from settings screen)
  [[[RACSignal combineLatest:@[RACAble(self.rawAlbumChartsForWeek), RACAbleWithStart(self.playCountFilter)]
                      reduce:^(id first, id second){
                        return first; // we only care about the raw album charts value
                      }] deliverOn:[RACScheduler scheduler]] subscribeNext:^(NSArray *rawAlbumChartsForWeek) {
                        NSLog(@"Filtering charts by playcount...");
                        @strongify(self);
                        NSArray *filteredCharts = [[rawAlbumChartsForWeek.rac_sequence filter:^BOOL(WeeklyAlbumChart *chart) {
                          @strongify(self);
                          return (chart.playcountValue > self.playCountFilter);
                        }] array];
                        self.albumChartsForWeek = filteredCharts;
                      }];
  
  // When the album charts gets changed, reload the table
  [[RACAble(self.albumChartsForWeek) deliverOn:[RACScheduler mainThreadScheduler]]
   subscribeNext:^(id x){
     @strongify(self);
     NSLog(@"Refreshing table...");
     [self.tableView reloadData];
     [self.tableView setContentOffset:CGPointZero animated:YES];
     self.showingLoading = NO;
   }];
  
  // Change displayed year by sliding the slideSelectView left or right
  self.slideSelectView.pullLeftCommand = [RACCommand commandWithCanExecuteSignal:RACAble(self.canMoveBackOneYear)];
  [self.slideSelectView.pullLeftCommand subscribeNext:^(id x) {
    @strongify(self);
    self.displayingYearsAgo += 1;
  }];
  self.slideSelectView.pullRightCommand = [RACCommand commandWithCanExecuteSignal:RACAble(self.canMoveForwardOneYear)];
  [self.slideSelectView.pullRightCommand subscribeNext:^(id x) {
    @strongify(self);
    self.displayingYearsAgo -= 1;
  }];
  
  // Monitor datasource array to determine empty view
  [RACAble(self.albumChartsForWeek) subscribeNext:^(NSArray *albumCharts) {
    @strongify(self);
    if ((albumCharts == nil) || ([albumCharts count] == 0)){
      self.showingEmpty = YES;
    }else{
      self.showingEmpty = NO;
    }
  }];
}

- (void)viewWillAppear:(BOOL)animated{
  [super viewWillAppear:animated];
  
}

- (void)viewDidAppear:(BOOL)animated{
  [super viewDidAppear:animated];
}

- (void)viewWillLayoutSubviews{
  CGRect r = self.view.bounds;
  CGFloat slideSelectHeight = 60.0f;
  
  [self.slideSelectView setTop:CGRectGetMinY(r) bottom:slideSelectHeight];
  self.slideSelectView.width = CGRectGetWidth(r);
  [self.tableView setTop:slideSelectHeight bottom:CGRectGetMaxY(r)];
  self.tableView.width = CGRectGetWidth(r);
  
  self.emptyView.frame = self.tableView.frame;
  self.errorView.frame = self.tableView.frame;
}

- (void)didReceiveMemoryWarning{
  [super didReceiveMemoryWarning];
  // Dispose of any resources that can be recreated.
  
}

#pragma mark - Private

// Hide nav bar and status bar on double tap
- (void)doDoubleTap:(UITapGestureRecognizer *)tap{
  if ([tap state] == UIGestureRecognizerStateEnded){
    if ([[UIApplication sharedApplication] isStatusBarHidden] == NO){
      [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationSlide];
      [self.navigationController setNavigationBarHidden:YES animated:YES];
    }else{
      [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationSlide];
      [self.navigationController setNavigationBarHidden:NO animated:YES];
    }
  }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
  return [self.albumChartsForWeek count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
  // We're currently only using one type of cell
  static NSString *CellIdentifier = @"TCSAlbumArtistPlayCountCell";
  TCSAlbumArtistPlayCountCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
  if (!cell) {
    cell = [[TCSAlbumArtistPlayCountCell alloc] init];
  }
  
  WeeklyAlbumChart *albumChart = [self.albumChartsForWeek objectAtIndex:indexPath.row];
  [cell setObject:albumChart];
  
  return cell;
}

#pragma mark - Table view delegate

// Selecting a cell just prints out its data right now
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  id object = [self.albumChartsForWeek objectAtIndex:indexPath.row];
  NSLog(@"%@", object);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath{
  // ask the cell for its height
  id object = [self.albumChartsForWeek objectAtIndex:indexPath.row];
  return [TCSAlbumArtistPlayCountCell heightForObject:object atIndexPath:indexPath tableView:tableView];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath{
  // If the object doesn't have an album URL yet, request it from the server then refresh the cell
  // (Kind of ugly, but RAC wasn't working inside the cell (managedobject?) for some reason
  TCSAlbumArtistPlayCountCell *albumCell = (TCSAlbumArtistPlayCountCell *)cell;
  WeeklyAlbumChart *albumChart = [self.albumChartsForWeek objectAtIndex:indexPath.row];
  if (albumChart.albumImageURL == nil) {
    [[[self.lastFMClient fetchImageURLForWeeklyAlbumChart:albumChart] deliverOn:[RACScheduler mainThreadScheduler]] subscribeNext:^(NSString *albumImageURL) {
      [albumCell refreshImage];
    }];
  }
}

#pragma mark - view getters

- (TCSSlideSelectView *)slideSelectView{
  if (!_slideSelectView){
    _slideSelectView = [[TCSSlideSelectView alloc] init];
  }
  return _slideSelectView;
}

- (UITableView *)tableView{
  if (!_tableView){
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundView = [[TCSInnerShadowView alloc] initWithColor:WHITE_SUBTLE shadowColor:GRAYCOLOR(210) shadowRadius:3.0f];
  }
  return _tableView;
}

// Spinning record animation
- (UIImageView *)loadingImageView{
  if (!_loadingImageView){
    _loadingImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    NSMutableArray *animationImages = [NSMutableArray arrayWithCapacity:12];
    for (int i = 1; i < 13; i++){
      [animationImages addObject:[UIImage imageNamed:[NSString stringWithFormat:@"loading%02i", i]]];
    }
    [_loadingImageView setAnimationImages:animationImages];
    _loadingImageView.animationDuration = 0.5f;
    _loadingImageView.animationRepeatCount = 0;
  }
  return _loadingImageView;
}

@end
