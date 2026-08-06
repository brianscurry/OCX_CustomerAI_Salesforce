({
    handleRecordUpdated: function (component, event, helper) {
        var changeType = event.getParams().changeType;

        if (changeType === 'ERROR') {
            helper.openStandardTask(component);
            return;
        }

        if (
            changeType !== 'LOADED' &&
            changeType !== 'CHANGED'
        ) {
            return;
        }

        if (component.get('v.resolved')) {
            return;
        }

        component.set('v.resolved', true);

        var taskRecord =
            component.get('v.taskRecord') || {};

        var description =
            taskRecord.Description || '';

        if (
            description.indexOf(
                'OCX_PUBLICATION_ID='
            ) === 0
        ) {
            component.set(
                'v.isReviewTask',
                true
            );

            return;
        }

        helper.openStandardTask(component);
    },

    handleClose: function (
        component,
        event,
        helper
    ) {
        var taskRecord =
            component.get('v.taskRecord') || {};

        if (taskRecord.WhatId) {
            helper.navigateToRecord(
                component,
                taskRecord.WhatId
            );

            return;
        }

        helper.openStandardTask(component);
    }
})