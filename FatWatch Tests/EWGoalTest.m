//
//  EWGoalTest.m
//  EatWatch
//
//  Created by Benjamin Ragheb on 1/28/10.
//  Copyright 2010 Benjamin Ragheb. All rights reserved.
//

#import "EWGoal.h"
#import "EWDatabase.h"
#import "EWDBMonth.h"


@interface EWGoalTest : XCTestCase 
@end

@implementation EWGoalTest


- (void)testUpgrade {
	EWDatabase *testdb = [[EWDatabase alloc] initWithSQLNamed:@"DBCreate3" bundle:[NSBundle bundleForClass:[self class]]];
	
	EWDBDay dbd;
	dbd.scaleWeight = 100;
	dbd.scaleFatWeight = 0;
	dbd.flags[0] = 0;
	dbd.flags[1] = 0;
	dbd.flags[2] = 0;
	dbd.flags[3] = 0;
	dbd.note = nil;
	[[testdb getDBMonth:0] setDBDay:&dbd onDay:1];
	[testdb commitChanges];
	
	[NSUserDefaults resetStandardUserDefaults];
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	[ud setInteger:0 forKey:@"GoalStartDate"];
	[ud setFloat:5 forKey:@"GoalWeightChangePerDay"];
	[ud setFloat:90 forKey:@"GoalWeight"];
	
	NSLog(@"BEFORE %@", [ud dictionaryRepresentation]);
	EWGoal *goal = [[EWGoal alloc] initWithDatabase:testdb];
	NSLog(@"AFTER %@", [ud dictionaryRepresentation]);
	
	XCTAssertNil([ud objectForKey:@"GoalStartDate"], @"start date removed");
	XCTAssertNil([ud objectForKey:@"GoalWeightChangePerDay"], @"change removed");
	XCTAssertNotNil([ud objectForKey:@"GoalWeight"], @"goal weight set");
	XCTAssertNotNil([ud objectForKey:@"GoalDate"], @"goal date set");
	XCTAssertEqual(goal.currentWeight, 100.0f, @"current weight");
	XCTAssertEqual(goal.endWeight, 90.0f, @"goal weight");

}


@end