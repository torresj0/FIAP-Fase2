package main

import (
	"encoding/json"
	"log"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// sendEvaluationEvent envia um evento para a fila SQS
func (a *App) sendEvaluationEvent(userID, flagName string, result bool) {
	// Se a URL da fila não foi configurada, apenas loga localmente e sai.
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		log.Printf("[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		log.Printf("Erro ao serializar evento SQS: %v", err)
		return
	}

	// Envia a mensagem
	out, err := a.SqsSvc.SendMessage(&sqs.SendMessageInput{
		MessageBody: aws.String(string(body)),
		QueueUrl:    aws.String(a.SqsQueueURL),
	})

	if err != nil {
		log.Printf("Erro ao enviar mensagem para SQS: %v", err)
		return
	}

	// Log SendMessage response details for debugging
	if out.MessageId != nil {
		log.Printf("SQS SendMessage MessageId: %s", *out.MessageId)
	}
	if out.MD5OfMessageBody != nil {
		log.Printf("SQS MD5OfMessageBody: %s", *out.MD5OfMessageBody)
	}
	log.Printf("Evento de avaliação enviado para SQS (Flag: %s, QueueURL: %s, Body: %s)", flagName, a.SqsQueueURL, string(body))

}