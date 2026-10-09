// Replaced by agent A's files, one per group (see ../../../runs/).
import Contracts
import SpecKit

public enum DoPPackChecks { public static let all: [SpecCheck<any DoPPacker>] = [] }
public enum DoPStreamChecks { public static let all: [SpecCheck<any DoPStageMaker>] = [] }
public enum FloatChecks { public static let all: [SpecCheck<any FloatOutput>] = [] }
public enum IntegerChecks { public static let all: [SpecCheck<any IntegerOutput>] = [] }
public enum RateChecks { public static let all: [SpecCheck<any RatePlanner>] = [] }
public enum VerdictChecks { public static let all: [SpecCheck<any BadgeVerdict>] = [] }
public enum DSTChecks { public static let all: [SpecCheck<any DSTDecoderMaker>] = [] }
