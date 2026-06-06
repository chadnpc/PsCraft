using System;
using System.Management.Automation;

namespace {mName}
{
    /// <summary>
    /// Cmdlet template for binary module.
    /// Replace this with your actual cmdlet implementation.
    /// </summary>
    [Cmdlet(VerbsCommon.Get, "Info")]
    [OutputType(typeof(string))]
    public class GetInfoCmdlet : PSCmdlet
    {
        [Parameter(Position = 0, Mandatory = false, ValueFromPipeline = false)]
        public string Name { get; set; } = string.Empty;

        protected override void ProcessRecord()
        {
            WriteObject($"Hello from {mName} binary module!");
        }
    }
}
