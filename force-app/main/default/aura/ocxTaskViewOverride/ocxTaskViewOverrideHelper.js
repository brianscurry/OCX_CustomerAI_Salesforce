({
    openStandardTask: function (component) {
        if (component.get('v.navigating')) {
            return;
        }

        component.set('v.navigating', true);

        var navigation =
            component.find('navService');

        navigation.navigate(
            {
                type: 'standard__recordPage',
                attributes: {
                    recordId:
                        component.get('v.recordId'),
                    objectApiName: 'Task',
                    actionName: 'view'
                },
                state: {
                    nooverride: '1'
                }
            },
            true
        );
    },

    navigateToRecord: function (
        component,
        recordId
    ) {
        if (component.get('v.navigating')) {
            return;
        }

        component.set('v.navigating', true);

        var navigation =
            component.find('navService');

        navigation.navigate(
            {
                type: 'standard__recordPage',
                attributes: {
                    recordId: recordId,
                    actionName: 'view'
                }
            },
            true
        );
    }
})