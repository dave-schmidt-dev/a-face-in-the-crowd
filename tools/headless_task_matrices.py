"""Fixed host-only matrices selected by focused or accumulated task membership."""


def selected_task_matrices(task_ids):
    """Return ordered immutable commands; duplicate task IDs never duplicate work."""
    if 'task2.model-resources' not in task_ids:
        return ()
    return (
        ('acquisition-python-compile', ('python3', '-m', 'py_compile',
          'tools/acquire-model-resources.py', 'tools/model_resource_acquisition_core.py',
          'tools/test_model_resource_acquisition.py')),
        ('acquisition-behavior', ('python3', 'tools/test_model_resource_acquisition.py')),
    )


def run_selected_task_matrices(task_ids, run):
    """Execute selected stages through the runner; failures stop subsequent stages."""
    for stage, command in selected_task_matrices(task_ids):
        run(list(command), stage)
