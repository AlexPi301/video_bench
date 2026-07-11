"""URL configuration for the Video Bench backend.

The backend is intentionally integrated without application-specific endpoints yet.
"""

from django.urls import path

from .benchmarks import (
    create_benchmark_run,
    delete_benchmark_run,
    get_benchmark_results,
    get_benchmark_run,
    get_benchmark_run_events,
    list_benchmark_runs,
    resume_benchmark_run,
    start_benchmark_run,
    update_benchmark_run,
)
from .impact_cycle import (
    cancel_impact_cycle_job,
    create_impact_cycle_job,
    get_impact_cycle_activities,
    get_impact_cycle_bundle,
    get_impact_cycle_job,
    get_impact_cycle_job_events,
    list_impact_cycle_jobs,
    serve_impact_cycle_file,
    upload_impact_cycle_video,
)
from .mounted_files import list_mounted_files, save_mounted_file, serve_mounted_file


urlpatterns = [
    path("api/benchmarks/runs/", list_benchmark_runs, name="benchmarks-run-list"),
    path("api/benchmarks/runs/create/", create_benchmark_run, name="benchmarks-run-create"),
    path("api/benchmarks/runs/<str:run_id>/", get_benchmark_run, name="benchmarks-run-detail"),
    path("api/benchmarks/runs/<str:run_id>/edit/", update_benchmark_run, name="benchmarks-run-edit"),
    path("api/benchmarks/runs/<str:run_id>/delete/", delete_benchmark_run, name="benchmarks-run-delete"),
    path("api/benchmarks/runs/<str:run_id>/start/", start_benchmark_run, name="benchmarks-run-start"),
    path("api/benchmarks/runs/<str:run_id>/resume/", resume_benchmark_run, name="benchmarks-run-resume"),
    path("api/benchmarks/runs/<str:run_id>/events/", get_benchmark_run_events, name="benchmarks-run-events"),
    path("api/benchmarks/runs/<str:run_id>/results/", get_benchmark_results, name="benchmarks-run-results"),
    path("api/mounted-files/", list_mounted_files, name="mounted-files-list"),
    path("api/mounted-files/file/", serve_mounted_file, name="mounted-files-file"),
    path("api/mounted-files/save/", save_mounted_file, name="mounted-files-save"),
    path("api/impact-cycle/uploads/", upload_impact_cycle_video, name="impact-cycle-upload"),
    path("api/impact-cycle/jobs/", create_impact_cycle_job, name="impact-cycle-job-create"),
    path("api/impact-cycle/jobs/list/", list_impact_cycle_jobs, name="impact-cycle-job-list"),
    path("api/impact-cycle/jobs/<str:job_id>/", get_impact_cycle_job, name="impact-cycle-job-detail"),
    path("api/impact-cycle/jobs/<str:job_id>/events/", get_impact_cycle_job_events, name="impact-cycle-job-events"),
    path("api/impact-cycle/jobs/<str:job_id>/bundle/", get_impact_cycle_bundle, name="impact-cycle-job-bundle"),
    path("api/impact-cycle/jobs/<str:job_id>/cancel/", cancel_impact_cycle_job, name="impact-cycle-job-cancel"),
    path("api/impact-cycle/activities/", get_impact_cycle_activities, name="impact-cycle-activities"),
    path("api/impact-cycle/file/", serve_impact_cycle_file, name="impact-cycle-file"),
]
