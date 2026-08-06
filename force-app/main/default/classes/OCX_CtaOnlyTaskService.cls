public without sharing class OCX_CtaOnlyTaskService implements Queueable {
    private static final String START_MARKER =
        '----- OCX WORKBOOK TASKS -----';

    private static final String END_MARKER =
        '----- END OCX WORKBOOK TASKS -----';

    private final Set<String> resourceIds;

    public OCX_CtaOnlyTaskService(Set<String> resourceIds) {
        this.resourceIds =
            resourceIds == null ? new Set<String>() : resourceIds;
    }

    public void execute(QueueableContext context) {
        if (resourceIds.isEmpty()) {
            return;
        }

        List<Task> actions = [
            SELECT
                Id,
                Subject,
                Description,
                WhatId,
                OCX_Action_Key__c,
                OCX_Action_Type__c,
                OCX_Parent_Action_Key__c,
                OCX_Sequence__c,
                OCX_Source_Resource_ID__c,
                OCX_Source_State__c
            FROM Task
            WHERE RecordType.DeveloperName = 'OCX_Action'
              AND OCX_Source_Resource_ID__c IN :resourceIds
              AND OCX_Source_State__c = 'ACTIVE'
        ];

        Map<String, Task> ctasByKey = new Map<String, Task>();
        Map<String, List<Task>> childrenByParent =
            new Map<String, List<Task>>();

        for (Task action : actions) {
            if (
                'CTA'.equalsIgnoreCase(action.OCX_Action_Type__c) &&
                String.isNotBlank(action.OCX_Action_Key__c)
            ) {
                ctasByKey.put(action.OCX_Action_Key__c, action);
            } else if (
                String.isNotBlank(action.OCX_Parent_Action_Key__c)
            ) {
                String parentKey = action.OCX_Parent_Action_Key__c;

                if (!childrenByParent.containsKey(parentKey)) {
                    childrenByParent.put(parentKey, new List<Task>());
                }

                childrenByParent.get(parentKey).add(action);
            }
        }

        List<Task> ctaUpdates = new List<Task>();
        List<Task> childUpdates = new List<Task>();

        for (String ctaKey : ctasByKey.keySet()) {
            Task cta = ctasByKey.get(ctaKey);
            List<Task> children = childrenByParent.get(ctaKey);
            String baseDescription = removeGeneratedSection(
                cta.Description
            );

            if (children == null || children.isEmpty()) {
                if (baseDescription != cta.Description) {
                    ctaUpdates.add(
                        new Task(
                            Id = cta.Id,
                            Description = baseDescription
                        )
                    );
                }
                continue;
            }

            children.sort(new ChildSequenceComparator());

            List<String> taskText = new List<String>();
            Integer position = 0;

            for (Task child : children) {
                position++;

                String item =
                    String.valueOf(position) + '. ' + safeText(child.Subject);

                if (String.isNotBlank(child.Description)) {
                    item +=
                        '\n   ' +
                        child.Description
                            .trim()
                            .replace('\r\n', '\n')
                            .replace('\r', '\n')
                            .replace('\n', '\n   ');
                }

                taskText.add(item);

                childUpdates.add(
                    new Task(
                        Id = child.Id,
                        WhatId = null,
                        OCX_Source_State__c = 'SUPERSEDED'
                    )
                );
            }

            String generated =
                START_MARKER +
                '\n\nTasks:\n\n' +
                String.join(taskText, '\n\n') +
                '\n\nOpen the published Customer AI action plan ' +
                'to review and work through the complete workbook.' +
                '\n\n' +
                END_MARKER;

            String finalDescription =
                String.isBlank(baseDescription)
                    ? generated
                    : baseDescription.trim() + '\n\n' + generated;

            if (finalDescription.length() > 32000) {
                finalDescription = finalDescription.substring(0, 32000);
            }

            ctaUpdates.add(
                new Task(
                    Id = cta.Id,
                    Description = finalDescription
                )
            );
        }

        if (!ctaUpdates.isEmpty()) {
            update ctaUpdates;
        }

        if (!childUpdates.isEmpty()) {
            update childUpdates;
        }
    }

    @TestVisible
    private static String removeGeneratedSection(String description) {
        if (String.isBlank(description)) {
            return '';
        }

        Integer startIndex = description.indexOf(START_MARKER);

        if (startIndex < 0) {
            return description;
        }

        Integer endIndex = description.indexOf(
            END_MARKER,
            startIndex
        );

        if (endIndex < 0) {
            return description.substring(0, startIndex).trim();
        }

        endIndex += END_MARKER.length();

        return (
            description.substring(0, startIndex) +
            description.substring(endIndex)
        ).trim();
    }

    private static String safeText(String value) {
        return String.isBlank(value) ? 'Untitled task' : value.trim();
    }

    public class ChildSequenceComparator implements Comparator<Task> {
        public Integer compare(Task leftTask, Task rightTask) {
            Decimal leftSequence = leftTask.OCX_Sequence__c;
            Decimal rightSequence = rightTask.OCX_Sequence__c;

            if (leftSequence == null && rightSequence == null) {
                return safeText(leftTask.Subject).compareTo(
                    safeText(rightTask.Subject)
                );
            }

            if (leftSequence == null) {
                return 1;
            }

            if (rightSequence == null) {
                return -1;
            }

            if (leftSequence < rightSequence) {
                return -1;
            }

            if (leftSequence > rightSequence) {
                return 1;
            }

            return safeText(leftTask.Subject).compareTo(
                safeText(rightTask.Subject)
            );
        }
    }
}