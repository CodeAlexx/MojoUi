"""Shared workflow executor value and result types."""

from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.execution import ExecutionPlan
from mojoui.app.workflow_render import RenderRequest


comptime WorkflowValueKind = Int32

comptime WV_NONE: WorkflowValueKind = 0
comptime WV_TEXT: WorkflowValueKind = 1
comptime WV_IMAGE: WorkflowValueKind = 2
comptime WV_VIDEO: WorkflowValueKind = 3
comptime WV_BBOX: WorkflowValueKind = 4
comptime WV_NUMBER: WorkflowValueKind = 5
comptime WV_MODEL: WorkflowValueKind = 6
comptime WV_CLIP: WorkflowValueKind = 7
comptime WV_VAE: WorkflowValueKind = 8
comptime WV_LATENT: WorkflowValueKind = 9
comptime WV_CONDITIONING: WorkflowValueKind = 10
comptime WV_LORA: WorkflowValueKind = 11

comptime WorkflowLaunchStatus = Int32

comptime WLS_STAGED: WorkflowLaunchStatus = 0
comptime WLS_LAUNCHED: WorkflowLaunchStatus = 1
comptime WLS_DONE: WorkflowLaunchStatus = 2
comptime WLS_FAILED: WorkflowLaunchStatus = 3


struct WorkflowDeviceConfig(Copyable, Movable):
    """Execution target for workflow model nodes."""

    var device_kind: String
    var device_index: Int32
    var require_gpu: Bool
    var dry_run: Bool
    var allow_cpu_fallback: Bool
    var mojodiffusion_root: String

    def __init__(out self):
        self.device_kind = String("gpu")
        self.device_index = 0
        self.require_gpu = True
        self.dry_run = True
        self.allow_cpu_fallback = False
        self.mojodiffusion_root = String("/home/alex/mojodiffusion")


struct WorkflowLaunchAction(Copyable, Movable):
    """A staged or launched GPU backend action."""

    var node_id: RetainedId
    var backend: String
    var entry: String
    var device_kind: String
    var device_index: Int32
    var command: String
    var output_path: String
    var status: WorkflowLaunchStatus
    var dry_run: Bool

    def __init__(out self):
        self.node_id = RET_ID_NONE
        self.backend = String("")
        self.entry = String("")
        self.device_kind = String("gpu")
        self.device_index = 0
        self.command = String("")
        self.output_path = String("")
        self.status = WLS_STAGED
        self.dry_run = True

    def __init__(
        out self,
        node_id: RetainedId,
        backend: String,
        entry: String,
        device_kind: String,
        device_index: Int32,
        command: String,
        output_path: String,
        status: WorkflowLaunchStatus,
        dry_run: Bool,
    ):
        self.node_id = node_id
        self.backend = backend.copy()
        self.entry = entry.copy()
        self.device_kind = device_kind.copy()
        self.device_index = device_index
        self.command = command.copy()
        self.output_path = output_path.copy()
        self.status = status
        self.dry_run = dry_run


struct WorkflowValue(Copyable, Movable):
    """A typed value produced by a node output port."""

    var node_id: RetainedId
    var port: String
    var kind: WorkflowValueKind
    var text: String
    var path: String
    var width: Int32
    var height: Int32
    var batch_size: Int32
    var seed: Int64
    var scalar: Float64

    def __init__(out self):
        self.node_id = RET_ID_NONE
        self.port = String("")
        self.kind = WV_NONE
        self.text = String("")
        self.path = String("")
        self.width = 0
        self.height = 0
        self.batch_size = 1
        self.seed = -1
        self.scalar = 0.0

    @staticmethod
    def text_value(node_id: RetainedId, port: String, text: String) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_TEXT
        value.text = text.copy()
        return value^

    @staticmethod
    def image_path(
        node_id: RetainedId,
        port: String,
        path: String,
        width: Int32,
        height: Int32,
        seed: Int64,
    ) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_IMAGE
        value.path = path.copy()
        value.width = width
        value.height = height
        value.seed = seed
        return value^

    @staticmethod
    def video_path(node_id: RetainedId, port: String, path: String) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_VIDEO
        value.path = path.copy()
        return value^

    @staticmethod
    def bbox_json(node_id: RetainedId, port: String, boxes_json: String) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_BBOX
        value.text = boxes_json.copy()
        return value^

    @staticmethod
    def number_value(node_id: RetainedId, port: String, value_text: String) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_NUMBER
        value.text = value_text.copy()
        return value^

    @staticmethod
    def handle_value(node_id: RetainedId, port: String, kind: WorkflowValueKind, handle: String) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = kind
        value.text = handle.copy()
        return value^

    @staticmethod
    def conditioning_value(node_id: RetainedId, port: String, text: String, scalar: Float64) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_CONDITIONING
        value.text = text.copy()
        value.scalar = scalar
        return value^

    @staticmethod
    def latent_value(
        node_id: RetainedId,
        port: String,
        width: Int32,
        height: Int32,
        batch_size: Int32,
        seed: Int64,
        scalar: Float64,
    ) -> WorkflowValue:
        var value = WorkflowValue()
        value.node_id = node_id
        value.port = port.copy()
        value.kind = WV_LATENT
        value.width = width
        value.height = height
        value.batch_size = batch_size
        value.seed = seed
        value.scalar = scalar
        return value^


struct WorkflowArtifact(Copyable, Movable):
    """A user-visible output from an execution run."""

    var node_id: RetainedId
    var kind: String
    var path: String
    var label: String

    def __init__(out self):
        self.node_id = RET_ID_NONE
        self.kind = String("")
        self.path = String("")
        self.label = String("")

    def __init__(out self, node_id: RetainedId, kind: String, path: String, label: String):
        self.node_id = node_id
        self.kind = kind.copy()
        self.path = path.copy()
        self.label = label.copy()


struct WorkflowExecutionResult(Movable):
    """Result of walking a graph execution plan."""

    var plan: ExecutionPlan
    var request: RenderRequest
    var device: WorkflowDeviceConfig
    var values: List[WorkflowValue]
    var artifacts: List[WorkflowArtifact]
    var launches: List[WorkflowLaunchAction]
    var logs: List[String]
    var success: Bool

    def __init__(
        out self,
        var plan: ExecutionPlan,
        request: RenderRequest,
        device: WorkflowDeviceConfig,
    ):
        self.plan = plan^
        self.request = request.copy()
        self.device = device.copy()
        self.values = List[WorkflowValue]()
        self.artifacts = List[WorkflowArtifact]()
        self.launches = List[WorkflowLaunchAction]()
        self.logs = List[String]()
        self.success = True

    def add_log(mut self, message: String):
        self.logs.append(message.copy())

    def add_value(mut self, value: WorkflowValue):
        self.values.append(value.copy())

    def add_artifact(mut self, artifact: WorkflowArtifact):
        self.artifacts.append(artifact.copy())

    def add_launch(mut self, launch: WorkflowLaunchAction):
        self.launches.append(launch.copy())

    def find_value(self, node_id: RetainedId, port: String) -> WorkflowValue:
        for i in range(len(self.values)):
            if self.values[i].node_id == node_id and self.values[i].port == port:
                return self.values[i].copy()
        return WorkflowValue()

    def first_artifact_path(self) -> String:
        if len(self.artifacts) == 0:
            return String("")
        return self.artifacts[0].path.copy()

    def launch_count(self) -> Int:
        return len(self.launches)
