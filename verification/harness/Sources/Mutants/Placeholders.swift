// Replaced by agent C's files, one per group (see ../../../runs/).
import Contracts
import SpecKit

public enum DoPPackMutants { public static let all: [Mutant<any DoPPacker>] = [] }
public enum DoPStreamMutants { public static let all: [Mutant<any DoPStageMaker>] = [] }
public enum FloatMutants { public static let all: [Mutant<any FloatOutput>] = [] }
public enum IntegerMutants { public static let all: [Mutant<any IntegerOutput>] = [] }
public enum RateMutants { public static let all: [Mutant<any RatePlanner>] = [] }
public enum VerdictMutants { public static let all: [Mutant<any BadgeVerdict>] = [] }
public enum DSTMutants { public static let all: [Mutant<any DSTDecoderMaker>] = [] }
