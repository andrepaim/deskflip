using Deskflip.Core;
using Deskflip.Runtime;

return args.Length == 0 ? ProbeRecorder.Record() : ExitCodes.InvalidConfiguration;
