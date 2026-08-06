trigger OCXCtaOnlyTasks on Task (after insert, after update) {
    OCX_CtaOnlyTaskHandler.handle(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}